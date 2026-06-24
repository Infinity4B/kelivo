import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

enum HtmlFragmentRenderMode { nativeSimple, nativeInteractive, webView }

HtmlFragmentRenderMode classifyHtmlFragment(String sanitizedHtml) {
  final fragment = html_parser.parseFragment(sanitizedHtml, container: 'div');
  var hasDeclarativeInteraction = false;
  var hasJsonScript = false;

  for (final node in fragment.nodes) {
    final result = _classifyNode(node);
    if (result.requiresWebView) return HtmlFragmentRenderMode.webView;
    hasDeclarativeInteraction =
        hasDeclarativeInteraction || result.hasDeclarativeInteraction;
    hasJsonScript = hasJsonScript || result.hasJsonScript;
  }

  if (hasDeclarativeInteraction || hasJsonScript) {
    return HtmlFragmentRenderMode.nativeInteractive;
  }
  return HtmlFragmentRenderMode.nativeSimple;
}

class _ClassificationResult {
  const _ClassificationResult({
    this.requiresWebView = false,
    this.hasDeclarativeInteraction = false,
    this.hasJsonScript = false,
  });

  final bool requiresWebView;
  final bool hasDeclarativeInteraction;
  final bool hasJsonScript;
}

_ClassificationResult _classifyNode(dom.Node node) {
  if (node is dom.Text) return const _ClassificationResult();
  if (node is! dom.Element) return const _ClassificationResult();

  final tag = node.localName?.toLowerCase() ?? '';
  if (tag == 'script') {
    final type = node.attributes['type']?.trim().toLowerCase();
    if (type == 'application/json') {
      return const _ClassificationResult(hasJsonScript: true);
    }
    return const _ClassificationResult(requiresWebView: true);
  }

  if (!_nativeTags.contains(tag) || _webViewOnlyTags.contains(tag)) {
    return const _ClassificationResult(requiresWebView: true);
  }

  if (_hasExecutableHandler(node) || !_hasSupportedStyle(node)) {
    return const _ClassificationResult(requiresWebView: true);
  }

  var hasDeclarativeInteraction = _hasDeclarativeInteraction(node);
  var hasJsonScript = false;
  for (final child in node.nodes) {
    final childResult = _classifyNode(child);
    if (childResult.requiresWebView) {
      return const _ClassificationResult(requiresWebView: true);
    }
    hasDeclarativeInteraction =
        hasDeclarativeInteraction || childResult.hasDeclarativeInteraction;
    hasJsonScript = hasJsonScript || childResult.hasJsonScript;
  }

  return _ClassificationResult(
    hasDeclarativeInteraction: hasDeclarativeInteraction,
    hasJsonScript: hasJsonScript,
  );
}

bool _hasExecutableHandler(dom.Element element) {
  return element.attributes.keys.any(
    (name) => name.toString().toLowerCase().startsWith('on'),
  );
}

bool _hasDeclarativeInteraction(dom.Element element) {
  return element.attributes.containsKey('data-html-interaction-id') ||
      element.attributes.containsKey('data-step') ||
      element.attributes['data-role'] == 'title' ||
      element.attributes['data-role'] == 'desc';
}

bool _hasSupportedStyle(dom.Element element) {
  final style = element.attributes['style'];
  if (style == null || style.trim().isEmpty) return true;

  for (final rawRule in style.split(';')) {
    final rule = rawRule.trim();
    if (rule.isEmpty) continue;
    final colon = rule.indexOf(':');
    if (colon <= 0) return false;
    final property = rule.substring(0, colon).trim().toLowerCase();
    final value = rule.substring(colon + 1).trim().toLowerCase();
    if (value.contains('url(')) return false;
    if (!_nativeStyleProperties.contains(property)) return false;
  }
  return true;
}

const Set<String> _nativeTags = {
  'a',
  'b',
  'br',
  'button',
  'code',
  'div',
  'em',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'i',
  'li',
  'ol',
  'p',
  'pre',
  'small',
  'span',
  'strong',
  'table',
  'tbody',
  'td',
  'th',
  'thead',
  'tr',
  'ul',
};

const Set<String> _webViewOnlyTags = {
  'canvas',
  'circle',
  'defs',
  'g',
  'img',
  'input',
  'label',
  'line',
  'lineargradient',
  'option',
  'path',
  'polygon',
  'polyline',
  'rect',
  'select',
  'stop',
  'svg',
  'text',
  'textarea',
};

const Set<String> _nativeStyleProperties = {
  'align-items',
  'background',
  'background-color',
  'border',
  'border-color',
  'border-radius',
  'border-style',
  'border-width',
  'color',
  'cursor',
  'display',
  'flex',
  'flex-direction',
  'flex-wrap',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'gap',
  'grid-template-columns',
  'justify-content',
  'letter-spacing',
  'line-height',
  'margin',
  'margin-bottom',
  'margin-left',
  'margin-right',
  'margin-top',
  'max-width',
  'padding',
  'padding-bottom',
  'padding-left',
  'padding-right',
  'padding-top',
  'text-align',
  'text-transform',
  'width',
};
