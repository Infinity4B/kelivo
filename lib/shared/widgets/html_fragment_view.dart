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
  WebViewController? _controller;
  winweb.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessageSubscription;
  Object? _platformError;
  double _height = 160;
  String? _loadedDocument;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_ensureLoaded());
  }

  @override
  void didUpdateWidget(covariant HtmlFragmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fragment.sanitizedHtml != widget.fragment.sanitizedHtml ||
        oldWidget.fragment.complete != widget.fragment.complete ||
        oldWidget.streaming != widget.streaming) {
      unawaited(_ensureLoaded(force: true));
    }
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
      if (_platformError != null && mounted) {
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
            setState(() {
              _height = value
                  .clamp(widget.minHeight, widget.maxHeight)
                  .toDouble();
            });
          }
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

  @override
  void dispose() {
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
        return Container(
          key: ValueKey('html-fragment-view-${widget.fragment.index}'),
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.55),
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SizedBox(
            height: _height,
            child: winweb.Webview(windowsController),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    return Container(
      key: ValueKey('html-fragment-view-${widget.fragment.index}'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SizedBox(
        height: _height,
        child: WebViewWidget(controller: controller),
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

  return '''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <base target="_blank">
  <style>
    html, body { margin: 0; padding: 0; background: transparent; color: $fg; }
    body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; overflow: hidden; }
    a { color: $link; }
    #html-fragment-root { box-sizing: border-box; width: 100%; background: $bg; }
    * { box-sizing: border-box; max-width: 100%; }
    img, svg, canvas, video { max-width: 100%; }
  </style>
</head>
<body>
  <div id="html-fragment-root">$bodyHtml</div>
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
      function height() {
        const root = document.getElementById('html-fragment-root');
        const h = Math.max(
          document.documentElement.scrollHeight,
          document.body.scrollHeight,
          root ? root.scrollHeight : 0
        );
        post('height', { value: h });
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
      window.addEventListener('load', height);
      new ResizeObserver(height).observe(document.documentElement);
      new MutationObserver(height).observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        characterData: true
      });
      height();
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
