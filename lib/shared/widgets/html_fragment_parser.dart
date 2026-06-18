import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

const String htmlFragmentMarkerStart = '<!-- html-render-start -->';
const String htmlFragmentMarkerEnd = '<!-- html-render-end -->';
const int htmlFragmentMaxProcessCount = 30;

class HtmlFragmentParseResult {
  const HtmlFragmentParseResult(this.segments);

  final List<HtmlFragmentSegment> segments;

  bool get hasHtml => segments.any((segment) => segment.isHtml);
}

class HtmlFragmentSegment {
  const HtmlFragmentSegment.markdown(this.text) : fragment = null;

  const HtmlFragmentSegment.html(this.fragment) : text = '';

  final String text;
  final HtmlFragment? fragment;

  bool get isMarkdown => fragment == null;
  bool get isHtml => fragment != null;
}

class HtmlFragment {
  const HtmlFragment({
    required this.index,
    required this.rawHtml,
    required this.sanitizedHtml,
    required this.complete,
  });

  final int index;
  final String rawHtml;
  final String sanitizedHtml;
  final bool complete;
}

HtmlFragmentParseResult parseHtmlFragmentSegments(
  String input, {
  bool streaming = false,
  int maxFragments = htmlFragmentMaxProcessCount,
}) {
  if (!input.contains(htmlFragmentMarkerStart)) {
    return HtmlFragmentParseResult([HtmlFragmentSegment.markdown(input)]);
  }

  final segments = <HtmlFragmentSegment>[];
  var cursor = 0;
  var fragmentIndex = 0;

  while (fragmentIndex < maxFragments) {
    final start = input.indexOf(htmlFragmentMarkerStart, cursor);
    if (start == -1) break;

    if (start > cursor) {
      segments.add(
        HtmlFragmentSegment.markdown(input.substring(cursor, start)),
      );
    }

    final contentStart = start + htmlFragmentMarkerStart.length;
    final end = input.indexOf(htmlFragmentMarkerEnd, contentStart);

    if (end == -1) {
      if (!streaming) {
        segments.add(HtmlFragmentSegment.markdown(input.substring(start)));
        cursor = input.length;
        break;
      }

      final rawHtml = input.substring(contentStart).trim();
      segments.add(
        HtmlFragmentSegment.html(
          HtmlFragment(
            index: fragmentIndex,
            rawHtml: rawHtml,
            sanitizedHtml: sanitizeHtmlFragment(rawHtml),
            complete: false,
          ),
        ),
      );
      cursor = input.length;
      fragmentIndex++;
      break;
    }

    final rawHtml = input.substring(contentStart, end).trim();
    segments.add(
      HtmlFragmentSegment.html(
        HtmlFragment(
          index: fragmentIndex,
          rawHtml: rawHtml,
          sanitizedHtml: sanitizeHtmlFragment(rawHtml),
          complete: true,
        ),
      ),
    );
    fragmentIndex++;
    cursor = end + htmlFragmentMarkerEnd.length;
  }

  if (cursor < input.length) {
    segments.add(HtmlFragmentSegment.markdown(input.substring(cursor)));
  }

  if (segments.isEmpty) {
    segments.add(HtmlFragmentSegment.markdown(input));
  }

  return HtmlFragmentParseResult(_mergeAdjacentMarkdownSegments(segments));
}

String sanitizeHtmlFragment(String rawHtml) {
  final decoded = decodeHtmlEntities(rawHtml).trim();
  if (decoded.isEmpty) return '';

  final fragment = html_parser.parseFragment(decoded, container: 'div');
  _sanitizeChildren(fragment.nodes);
  return fragment.nodes.map(_serializeHtmlNode).join().trim();
}

String decodeHtmlEntities(String input) {
  if (!input.contains('&')) return input;
  return input.replaceAllMapped(
    RegExp(r'&(#x?[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);'),
    (match) {
      final entity = match.group(1)!;
      if (entity.startsWith('#x') || entity.startsWith('#X')) {
        final value = int.tryParse(entity.substring(2), radix: 16);
        return value == null ? match.group(0)! : String.fromCharCode(value);
      }
      if (entity.startsWith('#')) {
        final value = int.tryParse(entity.substring(1));
        return value == null ? match.group(0)! : String.fromCharCode(value);
      }
      return _namedEntities[entity.toLowerCase()] ?? match.group(0)!;
    },
  );
}

const Map<String, String> _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
};

const Set<String> _allowedTags = {
  'a',
  'br',
  'button',
  'canvas',
  'circle',
  'code',
  'defs',
  'details',
  'div',
  'em',
  'g',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'img',
  'label',
  'input',
  'li',
  'line',
  'lineargradient',
  'ol',
  'option',
  'p',
  'path',
  'polygon',
  'polyline',
  'pre',
  'rect',
  'script',
  'select',
  'small',
  'span',
  'stop',
  'strong',
  'summary',
  'svg',
  'table',
  'tbody',
  'td',
  'text',
  'textarea',
  'th',
  'thead',
  'tr',
  'ul',
};

const Set<String> _forbiddenTags = {
  'base',
  'body',
  'embed',
  'form',
  'head',
  'html',
  'iframe',
  'link',
  'meta',
  'object',
  'style',
};

const Set<String> _urlAttributes = {
  'action',
  'formaction',
  'href',
  'src',
  'xlink:href',
};

void _sanitizeChildren(List<dom.Node> nodes) {
  for (final node in List<dom.Node>.from(nodes)) {
    if (node is! dom.Element) continue;
    _sanitizeElement(node);
  }
}

void _sanitizeElement(dom.Element element) {
  final tag = element.localName?.toLowerCase() ?? '';

  if (_forbiddenTags.contains(tag) || !_allowedTags.contains(tag)) {
    element.remove();
    return;
  }

  if (tag == 'script') {
    if (_isAllowedJsonScript(element)) {
      _sanitizeJsonScriptAttributes(element);
      return;
    }
    if (!_isAllowedExecutableScript(element)) {
      element.remove();
      return;
    }
    _sanitizeExecutableScriptAttributes(element);
    return;
  }

  _sanitizeAttributes(element);
  _sanitizeChildren(element.nodes);
}

bool _isAllowedExecutableScript(dom.Element element) {
  if (element.attributes.containsKey('src')) return false;
  final type = element.attributes['type']?.trim().toLowerCase();
  if (type == null || type.isEmpty) return true;
  return type == 'text/javascript' ||
      type == 'application/javascript' ||
      type == 'module';
}

void _sanitizeExecutableScriptAttributes(dom.Element element) {
  final type = element.attributes['type']?.trim();
  element.attributes.clear();
  if (type != null && type.isNotEmpty) {
    element.attributes['type'] = type;
  }
}

String stripExecutableScriptsFromHtmlFragment(String sanitizedHtml) {
  if (!sanitizedHtml.toLowerCase().contains('<script')) return sanitizedHtml;
  final fragment = html_parser.parseFragment(sanitizedHtml, container: 'div');
  for (final script in fragment.querySelectorAll('script')) {
    if (!_isAllowedJsonScript(script)) {
      script.remove();
    }
  }
  return fragment.nodes.map(_serializeHtmlNode).join().trim();
}

String _serializeHtmlNode(dom.Node node) {
  if (node is dom.Element) return node.outerHtml;
  if (node is dom.Text) return htmlEscape.convert(node.text);
  return '';
}

bool _isAllowedJsonScript(dom.Element element) {
  final type = element.attributes['type']?.trim().toLowerCase();
  if (type != 'application/json') return false;
  final interactionFor = element.attributes['data-html-interaction-for']
      ?.trim();
  if (interactionFor == null || interactionFor.isEmpty) return false;
  if (interactionFor.length > 96) return false;
  if (!RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(interactionFor)) return false;

  final jsonText = element.text.trim();
  if (jsonText.length > 200000) return false;
  try {
    jsonDecode(jsonText);
    return true;
  } catch (_) {
    return false;
  }
}

void _sanitizeJsonScriptAttributes(dom.Element element) {
  final interactionFor = element.attributes['data-html-interaction-for'];
  element.attributes.clear();
  element.attributes['type'] = 'application/json';
  if (interactionFor != null) {
    element.attributes['data-html-interaction-for'] = interactionFor;
  }
}

void _sanitizeAttributes(dom.Element element) {
  final attrs = Map<String, String>.from(element.attributes);
  for (final entry in attrs.entries) {
    final name = entry.key.toLowerCase();
    final value = decodeHtmlEntities(entry.value).trim();

    if (name.startsWith('on') || name == 'srcdoc') {
      element.attributes.remove(entry.key);
      continue;
    }

    if (name == 'style') {
      final sanitizedStyle = _sanitizeStyle(value);
      if (sanitizedStyle.isEmpty) {
        element.attributes.remove(entry.key);
      } else {
        element.attributes[entry.key] = sanitizedStyle;
      }
      continue;
    }

    if (_urlAttributes.contains(name) && !_isSafeUrl(value, name)) {
      element.attributes.remove(entry.key);
    }
  }
}

String _sanitizeStyle(String style) {
  final rules = <String>[];
  for (final rawRule in style.split(';')) {
    final rule = rawRule.trim();
    if (rule.isEmpty || !rule.contains(':')) continue;
    final lower = rule.toLowerCase();
    if (lower.contains('expression(') ||
        lower.contains('@import') ||
        lower.contains('behavior:') ||
        lower.contains('-moz-binding') ||
        lower.contains('url(')) {
      continue;
    }
    rules.add(rule);
  }
  return rules.join('; ');
}

bool _isSafeUrl(String value, String attrName) {
  if (value.isEmpty || value.startsWith('#')) return true;

  final compact = value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (compact.startsWith('javascript:') || compact.startsWith('vbscript:')) {
    return false;
  }

  if (compact.startsWith('data:')) {
    return attrName == 'src' && compact.startsWith('data:image/');
  }

  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return true;
  return uri.scheme == 'http' ||
      uri.scheme == 'https' ||
      uri.scheme == 'mailto' ||
      uri.scheme == 'tel';
}

List<HtmlFragmentSegment> _mergeAdjacentMarkdownSegments(
  List<HtmlFragmentSegment> input,
) {
  final merged = <HtmlFragmentSegment>[];
  for (final segment in input) {
    if (segment.isHtml) {
      merged.add(segment);
      continue;
    }
    if (merged.isNotEmpty && merged.last.isMarkdown) {
      final previous = merged.removeLast();
      merged.add(HtmlFragmentSegment.markdown(previous.text + segment.text));
    } else {
      merged.add(segment);
    }
  }
  return merged;
}
