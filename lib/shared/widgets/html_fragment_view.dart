import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import 'html_fragment_parser.dart';

class HtmlFragmentView extends StatefulWidget {
  const HtmlFragmentView({
    super.key,
    required this.fragment,
    required this.streaming,
    this.minHeight = 48,
    this.maxHeight = 720,
  });

  final HtmlFragment fragment;
  final bool streaming;
  final double minHeight;
  final double maxHeight;

  @override
  State<HtmlFragmentView> createState() => _HtmlFragmentViewState();
}

class _HtmlFragmentViewState extends State<HtmlFragmentView> {
  static const Duration _streamingLoadInterval = Duration(milliseconds: 80);

  WebViewController? _controller;
  winweb.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessageSubscription;
  Timer? _streamingLoadTimer;
  Object? _platformError;
  late double _height;
  String? _loadedDocument;
  bool _loadScheduled = false;
  bool _scheduledLoadForce = false;
  DateTime? _lastStreamingLoadAt;

  @override
  void initState() {
    super.initState();
    _height = widget.minHeight;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant HtmlFragmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fragment.sanitizedHtml != widget.fragment.sanitizedHtml ||
        oldWidget.fragment.complete != widget.fragment.complete ||
        oldWidget.streaming != widget.streaming) {
      _scheduleLoad(force: true);
    }
  }

  void _scheduleLoad({bool force = false}) {
    if (widget.streaming) {
      _scheduleStreamingLoad(force: force);
      return;
    }

    _streamingLoadTimer?.cancel();
    _streamingLoadTimer = null;
    _scheduledLoadForce = _scheduledLoadForce || force;
    if (_loadScheduled) return;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final shouldForce = _scheduledLoadForce;
      _loadScheduled = false;
      _scheduledLoadForce = false;
      unawaited(_ensureLoaded(force: shouldForce));
    });
  }

  void _scheduleStreamingLoad({bool force = false}) {
    _scheduledLoadForce = _scheduledLoadForce || force;
    final now = DateTime.now();
    final lastLoadAt = _lastStreamingLoadAt;
    final elapsed = lastLoadAt == null ? null : now.difference(lastLoadAt);
    final shouldLoadNow =
        _loadedDocument == null ||
        lastLoadAt == null ||
        elapsed! >= _streamingLoadInterval ||
        (force && widget.fragment.complete);

    if (shouldLoadNow) {
      _streamingLoadTimer?.cancel();
      _streamingLoadTimer = null;
      _queuePostFrameLoad(markStreamingLoad: true);
      return;
    }

    if (_streamingLoadTimer?.isActive ?? false) return;
    final delay = _streamingLoadInterval - elapsed;
    _streamingLoadTimer = Timer(delay, () {
      if (!mounted) return;
      _queuePostFrameLoad(markStreamingLoad: true);
    });
  }

  void _queuePostFrameLoad({bool markStreamingLoad = false}) {
    if (_loadScheduled) return;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final shouldForce = _scheduledLoadForce;
      _loadScheduled = false;
      _scheduledLoadForce = false;
      if (markStreamingLoad) {
        _lastStreamingLoadAt = DateTime.now();
      }
      unawaited(_ensureLoaded(force: shouldForce));
    });
  }

  Future<void> _ensureLoaded({bool force = false}) async {
    if (defaultTargetPlatform == TargetPlatform.linux) return;

    final document = buildHtmlFragmentDocument(
      sanitizedHtml: widget.fragment.sanitizedHtml,
      colorScheme: Theme.of(context).colorScheme,
      allowUserScripts: widget.fragment.complete,
    );
    if (!force && _loadedDocument == document) return;

    if (Platform.isWindows) {
      await _loadWindowsDocument(document);
      return;
    }

    try {
      final controller = _controller ?? _createController();
      if (controller == null) return;
      await controller.loadHtmlString(document);
      _loadedDocument = document;
      if (mounted) {
        setState(() => _platformError = null);
      }
    } catch (error, stack) {
      _setPlatformError(
        error,
        stack,
        ErrorDescription('while loading inline HTML'),
      );
    }
  }

  Future<void> _loadWindowsDocument(String document) async {
    try {
      final controller = await _ensureWindowsController();
      if (controller == null) return;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/kelivo_html_fragment_${widget.fragment.index}.html',
      );
      await file.writeAsString(document, flush: true);
      _loadedDocument = document;
      await controller.loadUrl(file.uri.toString());
    } catch (error, stack) {
      _platformError = error;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kelivo HTML fragment renderer',
          context: ErrorDescription('while loading inline HTML on Windows'),
        ),
      );
      if (mounted) setState(() {});
    }
  }

  Future<winweb.WebviewController?> _ensureWindowsController() async {
    final existing = _windowsController;
    if (existing != null) return existing;

    try {
      final controller = winweb.WebviewController();
      await controller.initialize();
      try {
        await controller.setBackgroundColor(const Color(0x00000000));
      } catch (_) {}
      _windowsMessageSubscription = controller.webMessage.listen((event) {
        final dynamic message = event;
        final text = message is String
            ? message
            : (message.content?.toString() ?? message.toString());
        _onHostMessageText(text);
      });
      _windowsController = controller;
      if (mounted) setState(() {});
      return controller;
    } catch (error, stack) {
      _platformError = error;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kelivo HTML fragment renderer',
          context: ErrorDescription('while creating a Windows inline WebView'),
        ),
      );
      if (mounted) setState(() {});
      return null;
    }
  }

  WebViewController? _createController() {
    try {
      final controller = _newWebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'HtmlFragmentHost',
          onMessageReceived: _onHostMessage,
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: _handleNavigationRequest,
            onWebResourceError: (error) {
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: StateError(
                    'HTML fragment WebView error ${error.errorCode}: '
                    '${error.description}',
                  ),
                  library: 'Kelivo HTML fragment renderer',
                ),
              );
            },
          ),
        );
      _trySetTransparentBackground(controller);
      _controller = controller;
      return controller;
    } catch (error, stack) {
      _setPlatformError(
        error,
        stack,
        ErrorDescription('while creating an inline WebView'),
      );
      return null;
    }
  }

  WebViewController _newWebViewController() {
    if (Platform.isMacOS || Platform.isIOS) {
      return WebViewController.fromPlatformCreationParams(
        WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        ),
      );
    }
    return WebViewController();
  }

  void _trySetTransparentBackground(WebViewController controller) {
    try {
      controller.setBackgroundColor(Colors.transparent);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kelivo HTML fragment renderer',
          context: ErrorDescription('while setting WebView background color'),
        ),
      );
    }
  }

  void _setPlatformError(
    Object error,
    StackTrace stack,
    DiagnosticsNode context,
  ) {
    _platformError = error;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'Kelivo HTML fragment renderer',
        context: context,
      ),
    );
    if (mounted) setState(() {});
  }

  String _fallbackMessage(AppLocalizations l10n, bool unsupported) {
    if (unsupported) return l10n.htmlFragmentLinuxUnsupportedMessage;
    final error = _platformError;
    if (error == null) return l10n.htmlFragmentWebViewUnavailableMessage;
    return '${l10n.htmlFragmentWebViewUnavailableMessage}\n${_compactError(error)}';
  }

  String _compactError(Object error) {
    final text = error.toString().trim();
    if (text.length <= 240) return text;
    return '${text.substring(0, 240)}...';
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final url = request.url;
    if (url == 'about:blank' ||
        url.startsWith('about:') ||
        url.startsWith('data:') ||
        url.startsWith('blob:') ||
        url.startsWith('file:')) {
      return NavigationDecision.navigate;
    }
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      unawaited(
        launchUrl(uri, mode: LaunchMode.externalApplication).catchError((
          error,
          stack,
        ) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'Kelivo HTML fragment renderer',
              context: ErrorDescription('while opening an external link'),
            ),
          );
          return false;
        }),
      );
    }
    return NavigationDecision.prevent;
  }

  void _onHostMessage(JavaScriptMessage message) {
    _onHostMessageText(message.message);
  }

  void _onHostMessageText(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      switch (data['type']) {
        case 'height':
          final value = (data['value'] as num?)?.toDouble();
          if (value != null && mounted) {
            final nextHeight = value
                .clamp(widget.minHeight, widget.maxHeight)
                .toDouble();
            if ((nextHeight - _height).abs() >= 0.5) {
              setState(() => _height = nextHeight);
            }
          }
          break;
        case 'wheel':
          _handleWheel(data);
          break;
        case 'console':
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: StateError(data['message']?.toString() ?? ''),
              library: 'Kelivo HTML fragment renderer console',
            ),
          );
          break;
        case 'error':
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: StateError(data['message']?.toString() ?? ''),
              library: 'Kelivo HTML fragment renderer script',
            ),
          );
          break;
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kelivo HTML fragment renderer',
          context: ErrorDescription('while handling a WebView host message'),
        ),
      );
    }
  }

  void _handleWheel(Map<String, dynamic> data) {
    final rawDeltaY = (data['deltaY'] as num?)?.toDouble();
    if (rawDeltaY == null || rawDeltaY == 0) return;
    final deltaMode = (data['deltaMode'] as num?)?.toInt() ?? 0;
    final multiplier = switch (deltaMode) {
      1 => 32.0,
      2 => _height,
      _ => 1.0,
    };
    final scrollable = Scrollable.maybeOf(context);
    final position = scrollable?.position;
    if (position == null || !position.hasPixels) return;
    position.pointerScroll(rawDeltaY * multiplier);
  }

  @override
  void dispose() {
    _streamingLoadTimer?.cancel();
    unawaited(_windowsMessageSubscription?.cancel());
    _windowsMessageSubscription = null;
    _windowsController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final unsupported = defaultTargetPlatform == TargetPlatform.linux;
    if (unsupported || _platformError != null) {
      return Container(
        key: ValueKey('html-fragment-view-${widget.fragment.index}'),
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(10),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Text(
          _fallbackMessage(l10n, unsupported),
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      final windowsController = _windowsController;
      if (windowsController != null) {
        return _buildWebViewFrame(child: winweb.Webview(windowsController));
      }
      return SizedBox(height: widget.minHeight);
    }

    return _buildWebViewFrame(child: WebViewWidget(controller: controller));
  }

  Widget _buildWebViewFrame({required Widget child}) {
    return Container(
      key: ValueKey('html-fragment-view-${widget.fragment.index}'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
      child: RepaintBoundary(
        child: SizedBox(height: _height, child: child),
      ),
    );
  }
}

String buildHtmlFragmentDocument({
  required String sanitizedHtml,
  required ColorScheme colorScheme,
  required bool allowUserScripts,
}) {
  final bodyHtml = allowUserScripts
      ? sanitizedHtml
      : stripExecutableScriptsFromHtmlFragment(sanitizedHtml);
  final bg = _cssColor(colorScheme.surface);
  final fg = _cssColor(colorScheme.onSurface);
  final link = _cssColor(colorScheme.primary);
  final controlBg = _cssColor(
    colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
  );
  final mutedBg = _cssColor(
    colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
  );
  final border = _cssColor(colorScheme.outlineVariant);
  final isDark = colorScheme.brightness == Brightness.dark;

  return '''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <base target="_blank">
  <style>
    :root {
      color-scheme: ${isDark ? 'dark' : 'light'};
      --kelivo-bg: $bg;
      --kelivo-fg: $fg;
      --kelivo-link: $link;
      --kelivo-control-bg: $controlBg;
      --kelivo-muted-bg: $mutedBg;
      --kelivo-border: $border;
    }
    html, body { margin: 0; padding: 0; background: transparent; color: var(--kelivo-fg); overflow: hidden; }
    body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; display: inline-block; max-width: 100vw; }
    a { color: var(--kelivo-link); }
    #html-fragment-root { box-sizing: border-box; display: inline-block; max-width: 100vw; background: var(--kelivo-bg); color: var(--kelivo-fg); overflow: hidden; vertical-align: top; }
    #html-fragment-content { box-sizing: border-box; display: inline-block; max-width: 100vw; vertical-align: top; }
    * { box-sizing: border-box; max-width: 100%; overscroll-behavior: contain; }
    img, svg, canvas, video { max-width: 100%; }
    button, input, select, textarea {
      background: var(--kelivo-control-bg);
      color: var(--kelivo-fg);
      border: 1px solid var(--kelivo-border);
      border-radius: 6px;
    }
    button { cursor: pointer; padding: 0.35em 0.7em; }
    input, select, textarea { padding: 0.3em 0.45em; }
    pre, code { background: var(--kelivo-muted-bg); color: var(--kelivo-fg); }
    pre { padding: 0.75em; overflow: hidden; white-space: pre-wrap; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid var(--kelivo-border); padding: 0.35em 0.55em; }
  </style>
</head>
<body>
  <div id="html-fragment-root"><div id="html-fragment-content">$bodyHtml</div></div>
  <script>
    (function () {
      const host = window.HtmlFragmentHost;
      function post(type, data) {
        const payload = JSON.stringify(Object.assign({ type }, data || {}));
        if (host && host.postMessage) {
          host.postMessage(payload);
          return;
        }
        if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
          window.chrome.webview.postMessage(payload);
        }
      }
      function dimensions() {
        const root = document.getElementById('html-fragment-root');
        if (!root) return;
        const content = document.getElementById('html-fragment-content') || root;
        const rootRect = root.getBoundingClientRect();
        const contentRect = content.getBoundingClientRect();
        const h = Math.max(root.scrollHeight, root.offsetHeight, rootRect.height, content.scrollHeight, content.offsetHeight, contentRect.height);
        post('height', { value: h });
      }
      function onWheel(event) {
        post('wheel', {
          deltaY: event.deltaY || 0,
          deltaMode: event.deltaMode || 0
        });
        event.preventDefault();
        event.stopPropagation();
      }
      function findInteractionScope(root, script) {
        const id = script.getAttribute('data-html-interaction-for');
        if (id) {
          const scoped = Array.from(root.querySelectorAll('[data-html-interaction-id]')).find(function (node) {
            return node.getAttribute('data-html-interaction-id') === id;
          });
          if (scoped) return scoped;
        }
        let previous = script.previousElementSibling;
        while (previous) {
          if (previous.hasAttribute && previous.hasAttribute('data-html-interaction-id')) return previous;
          previous = previous.previousElementSibling;
        }
        return root.querySelector('[data-html-interaction-id]') || root;
      }
      function interactionEntries(data) {
        if (!data || typeof data !== 'object') return null;
        return data.steps || data.items || data;
      }
      function applyInteractionStep(scope, entries, step) {
        const item = entries && entries[step];
        if (!item || typeof item !== 'object') return;
        const title = scope.querySelector('[data-role="title"]');
        const desc = scope.querySelector('[data-role="desc"]');
        if (title && item.title != null) title.textContent = String(item.title);
        if (desc && item.desc != null) desc.textContent = String(item.desc);
        scope.querySelectorAll('[data-step]').forEach(function (button) {
          const active = button.getAttribute('data-step') === step;
          button.setAttribute('aria-pressed', active ? 'true' : 'false');
          button.style.borderColor = active ? '#111111' : '#bbbbbb';
          button.style.background = active ? '#111111' : '#ffffff';
          button.style.color = active ? '#ffffff' : '#111111';
        });
        dimensions();
      }
      function hydrateJsonInteractions(root) {
        if (!root) return;
        root.querySelectorAll('script[type="application/json"]').forEach(function (script) {
          let data;
          try {
            data = JSON.parse(script.textContent || '{}');
          } catch (error) {
            post('error', { message: 'Invalid interaction JSON: ' + error.message });
            return;
          }
          const entries = interactionEntries(data);
          const scope = findInteractionScope(root, script);
          const buttons = Array.from(scope.querySelectorAll('[data-step]'));
          if (!entries || buttons.length === 0) return;
          buttons.forEach(function (button) {
            button.addEventListener('click', function () {
              const step = button.getAttribute('data-step');
              if (step) applyInteractionStep(scope, entries, step);
            });
          });
        });
      }
      function parseColor(value) {
        if (!value || value === 'transparent') return null;
        const match = value.match(/rgba?\\(([^)]+)\\)/i);
        if (!match) return null;
        const parts = match[1].split(',').map(function (part) { return parseFloat(part.trim()); });
        if (parts.length < 3 || parts.some(function (part) { return Number.isNaN(part); })) return null;
        const alpha = parts.length >= 4 ? parts[3] : 1;
        if (alpha === 0) return null;
        return { r: parts[0], g: parts[1], b: parts[2], a: alpha };
      }
      function luminance(color) {
        function channel(value) {
          value = value / 255;
          return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
      }
      function contrast(a, b) {
        const la = luminance(a);
        const lb = luminance(b);
        const lighter = Math.max(la, lb);
        const darker = Math.min(la, lb);
        return (lighter + 0.05) / (darker + 0.05);
      }
      function effectiveBackground(element) {
        let current = element;
        while (current && current !== document.documentElement) {
          const color = parseColor(getComputedStyle(current).backgroundColor);
          if (color) return color;
          current = current.parentElement;
        }
        return parseColor('$bg') || { r: 255, g: 255, b: 255, a: 1 };
      }
      function fixContrast(root) {
        if (!$isDark || !root) return;
        const black = { r: 0, g: 0, b: 0, a: 1 };
        const white = { r: 255, g: 255, b: 255, a: 1 };
        const nodes = [root].concat(Array.from(root.querySelectorAll('*')));
        nodes.forEach(function (node) {
          const style = getComputedStyle(node);
          const fg = parseColor(style.color);
          if (!fg) return;
          const bg = effectiveBackground(node);
          if (contrast(fg, bg) >= 3.8) return;
          node.style.color = contrast(black, bg) >= contrast(white, bg) ? '#111111' : '#ffffff';
        });
      }
      ['log', 'warn', 'error'].forEach(function (level) {
        const original = console[level];
        console[level] = function () {
          post('console', { level, message: Array.from(arguments).join(' ') });
          original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (event) {
        post('error', { message: event.message || 'Script error' });
      });
      window.addEventListener('unhandledrejection', function (event) {
        post('error', { message: String(event.reason || 'Unhandled rejection') });
      });
      window.addEventListener('wheel', onWheel, { passive: false, capture: true });
      document.addEventListener('wheel', onWheel, { passive: false, capture: true });
      window.addEventListener('load', dimensions);
      const root = document.getElementById('html-fragment-root');
      hydrateJsonInteractions(root);
      if (root) new ResizeObserver(dimensions).observe(root);
      if (root) fixContrast(root);
      new MutationObserver(function () {
        if (root) fixContrast(root);
        dimensions();
      }).observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        characterData: true
      });
      dimensions();
    })();
  </script>
</body>
</html>''';
}

String _cssColor(Color color) {
  final alpha = color.a.toDouble();
  final red = (color.r * 255).round();
  final green = (color.g * 255).round();
  final blue = (color.b * 255).round();
  return 'rgba($red, $green, $blue, ${alpha.toStringAsFixed(3)})';
}
