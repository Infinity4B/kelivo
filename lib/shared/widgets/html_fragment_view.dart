import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
  Object? _platformError;
  double _height = 160;
  String? _loadedDocument;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(covariant HtmlFragmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fragment.sanitizedHtml != widget.fragment.sanitizedHtml ||
        oldWidget.fragment.complete != widget.fragment.complete ||
        oldWidget.streaming != widget.streaming) {
      _ensureLoaded(force: true);
    }
  }

  void _ensureLoaded({bool force = false}) {
    if (defaultTargetPlatform == TargetPlatform.linux) return;

    final document = buildHtmlFragmentDocument(
      sanitizedHtml: widget.fragment.sanitizedHtml,
      colorScheme: Theme.of(context).colorScheme,
      allowUserScripts: widget.fragment.complete,
    );
    if (!force && _loadedDocument == document) return;

    final controller = _controller ?? _createController();
    if (controller == null) return;
    _loadedDocument = document;
    unawaited(controller.loadHtmlString(document));
  }

  WebViewController? _createController() {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
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
      _controller = controller;
      return controller;
    } catch (error, stack) {
      _platformError = error;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kelivo HTML fragment renderer',
          context: ErrorDescription('while creating an inline WebView'),
        ),
      );
      return null;
    }
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final url = request.url;
    if (url == 'about:blank' || url.startsWith('about:')) {
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
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final unsupported = defaultTargetPlatform == TargetPlatform.linux;
    if (unsupported || _platformError != null) {
      return Container(
        key: ValueKey('html-fragment-view-${widget.fragment.index}'),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(10),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Text(
          unsupported
              ? l10n.htmlFragmentLinuxUnsupportedMessage
              : l10n.htmlFragmentWebViewUnavailableMessage,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }

    return Container(
      key: ValueKey('html-fragment-view-${widget.fragment.index}'),
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
        if (!host || !host.postMessage) return;
        host.postMessage(JSON.stringify(Object.assign({ type }, data || {})));
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
