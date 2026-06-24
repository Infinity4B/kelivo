import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:url_launcher/url_launcher.dart';

import 'html_fragment_parser.dart';

class NativeHtmlFragmentView extends StatefulWidget {
  const NativeHtmlFragmentView({
    super.key,
    required this.fragment,
    this.enableDeclarativeInteractions = false,
  });

  final HtmlFragment fragment;
  final bool enableDeclarativeInteractions;

  @override
  State<NativeHtmlFragmentView> createState() => _NativeHtmlFragmentViewState();
}

class _NativeHtmlFragmentViewState extends State<NativeHtmlFragmentView> {
  String? _selectedStep;

  @override
  void didUpdateWidget(covariant NativeHtmlFragmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fragment.sanitizedHtml != widget.fragment.sanitizedHtml) {
      _selectedStep = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fragment = html_parser.parseFragment(
      widget.fragment.sanitizedHtml,
      container: 'div',
    );
    final interaction = widget.enableDeclarativeInteractions
        ? _HtmlInteractionData.parse(fragment)
        : const _HtmlInteractionData.empty();
    final selectedStep = _selectedStep ?? interaction.initialStep;
    final renderer = _NativeHtmlRenderer(
      context: context,
      interaction: interaction,
      selectedStep: selectedStep,
      onStepSelected: (step) => setState(() => _selectedStep = step),
    );
    final children = renderer.renderNodes(fragment.nodes);
    if (children.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _NativeHtmlRenderer {
  const _NativeHtmlRenderer({
    required this.context,
    required this.interaction,
    required this.selectedStep,
    required this.onStepSelected,
  });

  final BuildContext context;
  final _HtmlInteractionData interaction;
  final String? selectedStep;
  final ValueChanged<String> onStepSelected;

  TextStyle get _baseStyle {
    return DefaultTextStyle.of(context).style.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      height: 1.55,
    );
  }

  List<Widget> renderNodes(List<dom.Node> nodes) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final widget = renderBlock(node, _baseStyle, null);
      if (widget != null) widgets.add(widget);
    }
    return widgets;
  }

  Widget? renderBlock(dom.Node node, TextStyle style, Color? backgroundColor) {
    if (node is dom.Text) {
      final text = _normalizeText(node.text);
      if (text.isEmpty) return null;
      return Text(text, style: style);
    }
    if (node is! dom.Element) return null;

    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'script') return null;
    if (tag == 'br') return const SizedBox(height: 8);
    if (tag == 'ul' || tag == 'ol') {
      return _renderList(
        node,
        style,
        backgroundColor: backgroundColor,
        ordered: tag == 'ol',
      );
    }
    if (tag == 'table') return _renderTable(node, style, backgroundColor);
    if (tag == 'pre') return _renderPre(node, style, backgroundColor);
    if (tag == 'button') return _renderButton(node, style, backgroundColor);

    final styled = _ElementStyle.from(node, context);
    final effectiveBackground = _effectiveBackground(
      styled.backgroundColor,
      backgroundColor,
    );
    final nextStyle = _ensureReadableTextStyle(
      styled.applyTextStyle(_styleForTag(tag, style)),
      effectiveBackground,
    );
    final replacement = _replacementFor(node);
    if (replacement != null) {
      return styled.wrap(context, Text(replacement, style: nextStyle));
    }
    final inlineOnly = _hasOnlyInlineChildren(node);
    final child = inlineOnly
        ? _richTextFor(node.nodes, nextStyle, effectiveBackground)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: renderChildren(node, nextStyle, effectiveBackground),
          );
    return styled.wrap(context, child);
  }

  List<Widget> renderChildren(
    dom.Element element,
    TextStyle style,
    Color? backgroundColor,
  ) {
    final styleMap = _styleMap(element);
    final display = styleMap['display']?.toLowerCase();
    final children = <Widget>[];
    for (final node in element.nodes) {
      final child = renderBlock(node, style, backgroundColor);
      if (child != null) children.add(child);
    }
    if (display == 'flex') {
      final gap = _parseCssSize(styleMap['gap']);
      final columnGap = _parseCssSize(styleMap['column-gap']) ?? gap;
      final rowGap = _parseCssSize(styleMap['row-gap']) ?? gap;
      return [
        Wrap(
          spacing: columnGap ?? 0,
          runSpacing: rowGap ?? 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      ];
    }
    if (display == 'grid') {
      final gap = _parseCssSize(styleMap['gap']) ?? 0;
      final columnGap = _parseCssSize(styleMap['column-gap']) ?? gap;
      final rowGap = _parseCssSize(styleMap['row-gap']) ?? gap;
      final columns = _parseGridTemplateColumns(
        styleMap['grid-template-columns'],
      );
      if (columns.length == children.length && columns.isNotEmpty) {
        return [
          _gridRow(
            children: children,
            columns: columns,
            gap: columnGap,
            alignItems: styleMap['align-items'],
          ),
        ];
      }
      return [
        Wrap(
          spacing: columnGap,
          runSpacing: rowGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      ];
    }
    return children;
  }

  Widget _gridRow({
    required List<Widget> children,
    required List<_GridColumn> columns,
    required double gap,
    required String? alignItems,
  }) {
    final rowChildren = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0 && gap > 0) rowChildren.add(SizedBox(width: gap));
      rowChildren.add(columns[i].wrap(children[i]));
    }
    return Row(
      crossAxisAlignment: _crossAxisAlignmentForAlignItems(alignItems),
      children: rowChildren,
    );
  }

  InlineSpan renderInline(
    dom.Node node,
    TextStyle style,
    Color? backgroundColor,
  ) {
    if (node is dom.Text) return TextSpan(text: node.text, style: style);
    if (node is! dom.Element) return const TextSpan(text: '');

    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'br') return const TextSpan(text: '\n');

    final styled = _ElementStyle.from(node, context);
    final effectiveBackground = _effectiveBackground(
      styled.backgroundColor,
      backgroundColor,
    );
    final nextStyle = _ensureReadableTextStyle(
      styled.applyTextStyle(_styleForTag(tag, style)),
      effectiveBackground,
    );
    final replacement = _replacementFor(node);
    if (replacement != null) {
      return TextSpan(text: replacement, style: nextStyle);
    }
    final children = node.nodes
        .map((child) => renderInline(child, nextStyle, effectiveBackground))
        .toList();
    if (tag == 'a') {
      final href = node.attributes['href'];
      final linkStyle = _ensureReadableTextStyle(
        nextStyle.copyWith(color: Theme.of(context).colorScheme.primary),
        effectiveBackground,
      );
      return TextSpan(
        style: linkStyle,
        recognizer: href == null
            ? null
            : (TapGestureRecognizer()..onTap = () => _openUrl(href)),
        children: children,
      );
    }
    return TextSpan(style: nextStyle, children: children);
  }

  Widget _richTextFor(
    List<dom.Node> nodes,
    TextStyle style,
    Color? backgroundColor,
  ) {
    return RichText(
      text: TextSpan(
        style: style,
        children: nodes
            .map((node) => renderInline(node, style, backgroundColor))
            .toList(),
      ),
    );
  }

  Widget _renderButton(
    dom.Element element,
    TextStyle style,
    Color? backgroundColor,
  ) {
    final step = element.attributes['data-step'];
    final active = step != null && step == selectedStep;
    final label = element.text.trim();
    final cs = Theme.of(context).colorScheme;
    final styled = _ElementStyle.from(element, context);
    final bg = active ? cs.onSurface : (styled.backgroundColor ?? cs.surface);
    final fg = _ensureReadableColor(
      active ? cs.surface : (styled.textColor ?? style.color ?? cs.onSurface),
      _effectiveBackground(bg, backgroundColor),
    );
    return Padding(
      padding: styled.margin ?? EdgeInsets.zero,
      child: GestureDetector(
        onTap: step == null ? null : () => onStepSelected(step),
        child: MouseRegion(
          cursor: step == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: Container(
            padding:
                styled.padding ??
                const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: styled.borderRadius ?? BorderRadius.circular(999),
              border: Border.all(
                color: active ? cs.onSurface : cs.outlineVariant,
              ),
            ),
            child: Text(
              label,
              style: style.copyWith(color: fg, fontSize: style.fontSize ?? 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _renderList(
    dom.Element element,
    TextStyle style, {
    Color? backgroundColor,
    required bool ordered,
  }) {
    final items = element.children
        .where((child) => child.localName?.toLowerCase() == 'li')
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ordered ? '${i + 1}. ' : '• ', style: style),
              Expanded(
                child: _richTextFor(items[i].nodes, style, backgroundColor),
              ),
            ],
          ),
      ],
    );
  }

  Widget _renderPre(
    dom.Element element,
    TextStyle style,
    Color? backgroundColor,
  ) {
    final styled = _ElementStyle.from(element, context);
    final effectiveBackground = _effectiveBackground(
      styled.backgroundColor,
      backgroundColor,
    );
    return styled.wrap(
      context,
      SelectableText(
        element.text,
        style: _ensureReadableTextStyle(
          styled.applyTextStyle(style.copyWith(fontFamily: 'monospace')),
          effectiveBackground,
        ),
      ),
    );
  }

  Widget _renderTable(
    dom.Element element,
    TextStyle style,
    Color? backgroundColor,
  ) {
    final rows = element.querySelectorAll('tr');
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: TableBorder.all(
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      children: [
        for (final row in rows)
          TableRow(
            children: [
              for (final cell in row.children.where((child) {
                final tag = child.localName?.toLowerCase();
                return tag == 'td' || tag == 'th';
              }))
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: _richTextFor(
                    cell.nodes,
                    _styleForTag(cell.localName?.toLowerCase() ?? '', style),
                    backgroundColor,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  TextStyle _styleForTag(String tag, TextStyle style) {
    return switch (tag) {
      'strong' || 'b' || 'th' => style.copyWith(fontWeight: FontWeight.w700),
      'em' || 'i' => style.copyWith(fontStyle: FontStyle.italic),
      'small' => style.copyWith(fontSize: (style.fontSize ?? 14) * 0.85),
      'code' => style.copyWith(fontFamily: 'monospace'),
      'h1' => style.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        height: 1.25,
      ),
      'h2' => style.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        height: 1.25,
      ),
      'h3' => style.copyWith(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      'h4' => style.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
      'h5' || 'h6' => style.copyWith(fontWeight: FontWeight.w700),
      _ => style,
    };
  }

  bool _hasOnlyInlineChildren(dom.Element element) {
    return element.nodes.every((node) {
      if (node is dom.Text) return true;
      if (node is! dom.Element) return true;
      final tag = node.localName?.toLowerCase() ?? '';
      return _inlineTags.contains(tag) && _hasOnlyInlineChildren(node);
    });
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String? _replacementFor(dom.Element element) {
    final role = element.attributes['data-role'];
    if (role == null) return null;
    return interaction.replacementFor(role, selectedStep);
  }
}

class _HtmlInteractionData {
  const _HtmlInteractionData(this.entries, this.initialStep);

  const _HtmlInteractionData.empty() : entries = const {}, initialStep = null;

  final Map<String, Map<String, dynamic>> entries;
  final String? initialStep;

  static _HtmlInteractionData parse(dom.DocumentFragment fragment) {
    final steps = <String>[];
    for (final button in fragment.querySelectorAll('[data-step]')) {
      final step = button.attributes['data-step'];
      if (step != null && step.isNotEmpty) steps.add(step);
    }

    final entries = <String, Map<String, dynamic>>{};
    for (final script in fragment.querySelectorAll(
      'script[type="application/json"]',
    )) {
      try {
        final decoded = jsonDecode(script.text.trim());
        final source = decoded is Map<String, dynamic>
            ? (decoded['steps'] is Map<String, dynamic>
                  ? decoded['steps'] as Map<String, dynamic>
                  : decoded)
            : const <String, dynamic>{};
        for (final entry in source.entries) {
          if (entry.value is Map<String, dynamic>) {
            entries[entry.key] = entry.value as Map<String, dynamic>;
          }
        }
      } catch (_) {}
    }
    return _HtmlInteractionData(entries, steps.isEmpty ? null : steps.first);
  }

  String? replacementFor(String role, String? selectedStep) {
    final step = selectedStep;
    if (step == null) return null;
    final entry = entries[step];
    final value = switch (role) {
      'title' => entry?['title'],
      'desc' => entry?['desc'],
      _ => null,
    };
    return value?.toString();
  }
}

class _ElementStyle {
  const _ElementStyle({
    this.textColor,
    this.backgroundColor,
    this.padding,
    this.margin,
    this.borderRadius,
    this.border,
    this.boxShadow,
    this.minWidth,
    this.maxWidth,
    this.width,
    this.minHeight,
    this.maxHeight,
    this.height,
    this.opacity,
    this.fontSize,
    this.fontWeight,
    this.fontStyle,
    this.lineHeight,
    this.textAlign,
    this.textDecoration,
    this.textDecorationColor,
    this.textDecorationStyle,
    this.textDecorationThickness,
  });

  final Color? textColor;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;
  final double? minWidth;
  final double? maxWidth;
  final double? width;
  final double? minHeight;
  final double? maxHeight;
  final double? height;
  final double? opacity;
  final double? fontSize;
  final FontWeight? fontWeight;
  final FontStyle? fontStyle;
  final double? lineHeight;
  final TextAlign? textAlign;
  final TextDecoration? textDecoration;
  final Color? textDecorationColor;
  final TextDecorationStyle? textDecorationStyle;
  final double? textDecorationThickness;

  static _ElementStyle from(dom.Element element, BuildContext context) {
    final style = _styleMap(element);
    final borderRadius = _parseCssSize(style['border-radius']);
    return _ElementStyle(
      textColor: _parseColor(style['color']),
      backgroundColor: _parseColor(
        style['background-color'] ?? style['background'],
      ),
      padding: _parseBox(style, 'padding'),
      margin: _parseBox(style, 'margin'),
      borderRadius: borderRadius == null
          ? null
          : BorderRadius.circular(borderRadius),
      border: _parseBorder(style, context),
      boxShadow: _parseBoxShadow(style['box-shadow']),
      minWidth: _parseCssSize(style['min-width']),
      maxWidth: _parseCssSize(style['max-width']),
      width: _parseCssSize(style['width']),
      minHeight: _parseCssSize(style['min-height']),
      maxHeight: _parseCssSize(style['max-height']),
      height: _parseCssSize(style['height']),
      opacity: _parseOpacity(style['opacity']),
      fontSize: _parseCssSize(style['font-size']),
      fontWeight: _parseFontWeight(style['font-weight']),
      fontStyle: style['font-style']?.toLowerCase() == 'italic'
          ? FontStyle.italic
          : null,
      lineHeight: _parseLineHeight(style['line-height']),
      textAlign: _parseTextAlign(style['text-align']),
      textDecoration: _parseTextDecoration(style),
      textDecorationColor: _parseColor(style['text-decoration-color']),
      textDecorationStyle: _parseTextDecorationStyle(
        style['text-decoration-style'],
      ),
      textDecorationThickness: _parseCssSize(
        style['text-decoration-thickness'],
      ),
    );
  }

  TextStyle applyTextStyle(TextStyle style) {
    return style.copyWith(
      color: textColor ?? style.color,
      fontSize: fontSize ?? style.fontSize,
      fontWeight: fontWeight ?? style.fontWeight,
      fontStyle: fontStyle ?? style.fontStyle,
      height: lineHeight ?? style.height,
      decoration: textDecoration ?? style.decoration,
      decorationColor: textDecorationColor ?? style.decorationColor,
      decorationStyle: textDecorationStyle ?? style.decorationStyle,
      decorationThickness: textDecorationThickness ?? style.decorationThickness,
    );
  }

  Widget wrap(BuildContext context, Widget child) {
    Widget current = child;
    if (textAlign != null && child is RichText) {
      current = RichText(text: child.text, textAlign: textAlign!);
    }
    if (padding != null ||
        backgroundColor != null ||
        border != null ||
        borderRadius != null ||
        boxShadow != null ||
        width != null ||
        height != null ||
        _constraints != null) {
      current = Container(
        width: width,
        height: height,
        constraints: _constraints,
        padding: padding,
        decoration:
            backgroundColor == null &&
                border == null &&
                borderRadius == null &&
                boxShadow == null
            ? null
            : BoxDecoration(
                color: backgroundColor,
                border: border,
                borderRadius: borderRadius,
                boxShadow: boxShadow,
              ),
        child: current,
      );
    }
    if (opacity != null) current = Opacity(opacity: opacity!, child: current);
    if (margin != null) current = Padding(padding: margin!, child: current);
    return current;
  }

  BoxConstraints? get _constraints {
    if (minWidth == null &&
        maxWidth == null &&
        minHeight == null &&
        maxHeight == null) {
      return null;
    }
    return BoxConstraints(
      minWidth: minWidth ?? 0,
      maxWidth: maxWidth ?? double.infinity,
      minHeight: minHeight ?? 0,
      maxHeight: maxHeight ?? double.infinity,
    );
  }
}

Map<String, String> _styleMap(dom.Element element) {
  final result = <String, String>{};
  final style = element.attributes['style'];
  if (style == null) return result;
  for (final rawRule in style.split(';')) {
    final colon = rawRule.indexOf(':');
    if (colon <= 0) continue;
    result[rawRule.substring(0, colon).trim().toLowerCase()] = rawRule
        .substring(colon + 1)
        .trim();
  }
  return result;
}

EdgeInsetsGeometry? _parseBox(Map<String, String> style, String prefix) {
  final all = _parseCssSize(style[prefix]);
  final top = _parseCssSize(style['$prefix-top']) ?? all;
  final right = _parseCssSize(style['$prefix-right']) ?? all;
  final bottom = _parseCssSize(style['$prefix-bottom']) ?? all;
  final left = _parseCssSize(style['$prefix-left']) ?? all;
  if (top == null && right == null && bottom == null && left == null) {
    return null;
  }
  return EdgeInsets.fromLTRB(left ?? 0, top ?? 0, right ?? 0, bottom ?? 0);
}

BoxBorder? _parseBorder(Map<String, String> style, BuildContext context) {
  final hasBorder =
      style.containsKey('border') ||
      style.containsKey('border-width') ||
      style.containsKey('border-style') ||
      style.containsKey('border-color') ||
      style.keys.any(
        (key) => RegExp(r'^border-(top|right|bottom|left)(-|$)').hasMatch(key),
      );
  if (!hasBorder) return null;

  return Border(
    top: _parseBorderSide(style, context, 'top'),
    right: _parseBorderSide(style, context, 'right'),
    bottom: _parseBorderSide(style, context, 'bottom'),
    left: _parseBorderSide(style, context, 'left'),
  );
}

BorderSide _parseBorderSide(
  Map<String, String> style,
  BuildContext context,
  String side,
) {
  final sideValue = style['border-$side'];
  final allValue = style['border'];
  final hasSideOrAll =
      sideValue != null ||
      allValue != null ||
      style.containsKey('border-$side-width') ||
      style.containsKey('border-$side-style') ||
      style.containsKey('border-$side-color') ||
      style.containsKey('border-width') ||
      style.containsKey('border-style') ||
      style.containsKey('border-color');
  if (!hasSideOrAll) return BorderSide.none;

  final borderStyle =
      style['border-$side-style'] ??
      _firstBorderStyle(sideValue) ??
      style['border-style'] ??
      _firstBorderStyle(allValue);
  if (borderStyle == 'none' || borderStyle == 'hidden') return BorderSide.none;

  final width =
      _parseCssSize(style['border-$side-width']) ??
      _firstBorderWidth(sideValue) ??
      _parseCssSize(style['border-width']) ??
      _firstBorderWidth(allValue) ??
      1;
  final color =
      _parseColor(style['border-$side-color'] ?? sideValue) ??
      _parseColor(style['border-color'] ?? allValue) ??
      Theme.of(context).colorScheme.outlineVariant;
  return BorderSide(color: color, width: width);
}

double? _firstBorderWidth(String? value) {
  if (value == null) return null;
  for (final part in value.split(RegExp(r'\s+'))) {
    final parsed = _parseCssSize(part);
    if (parsed != null) return parsed;
  }
  return null;
}

String? _firstBorderStyle(String? value) {
  if (value == null) return null;
  const styles = {
    'none',
    'hidden',
    'solid',
    'dashed',
    'dotted',
    'double',
    'groove',
    'ridge',
    'inset',
    'outset',
  };
  for (final part in value.trim().toLowerCase().split(RegExp(r'\s+'))) {
    if (styles.contains(part)) return part;
  }
  return null;
}

List<BoxShadow>? _parseBoxShadow(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text.isEmpty || text == 'none' || text.contains('inset')) return null;

  final color = _parseColor(text) ?? Colors.black.withValues(alpha: 0.18);
  final numericSource = text
      .replaceAll(RegExp(r'rgba?\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'#[0-9a-f]{3,8}'), ' ');
  final sizes = RegExp(r'-?\d+(?:\.\d+)?(?:px|em|rem)?')
      .allMatches(numericSource)
      .map((match) => _parseCssSize(match.group(0)))
      .whereType<double>()
      .toList();
  if (sizes.length < 2) return null;

  return [
    BoxShadow(
      color: color,
      offset: Offset(sizes[0], sizes[1]),
      blurRadius: sizes.length >= 3 ? math.max(0, sizes[2]) : 0,
      spreadRadius: sizes.length >= 4 ? sizes[3] : 0,
    ),
  ];
}

double? _parseOpacity(String? value) {
  if (value == null) return null;
  final parsed = double.tryParse(value.trim());
  if (parsed == null) return null;
  return parsed.clamp(0, 1).toDouble();
}

Color? _parseColor(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text.isEmpty || text == 'transparent') return Colors.transparent;
  final hex = RegExp(
    r'#([0-9a-f]{6}|[0-9a-f]{3})(?![0-9a-f])',
  ).firstMatch(text);
  if (hex != null) {
    var raw = hex.group(1)!;
    if (raw.length == 3) raw = raw.split('').map((c) => '$c$c').join();
    return Color(int.parse('ff$raw', radix: 16));
  }
  final rgb = RegExp(r'rgba?\(([^)]+)\)').firstMatch(text);
  if (rgb != null) {
    final parts = rgb
        .group(1)!
        .split(',')
        .map((part) => double.tryParse(part.trim()))
        .toList();
    if (parts.length >= 3 &&
        parts[0] != null &&
        parts[1] != null &&
        parts[2] != null) {
      final alpha = parts.length >= 4 ? (parts[3] ?? 1) : 1.0;
      return Color.fromRGBO(
        parts[0]!.round(),
        parts[1]!.round(),
        parts[2]!.round(),
        alpha.clamp(0, 1),
      );
    }
  }
  return switch (text) {
    'black' => Colors.black,
    'white' => Colors.white,
    'red' => Colors.red,
    'blue' => Colors.blue,
    'green' => Colors.green,
    'gray' || 'grey' => Colors.grey,
    _ => null,
  };
}

Color? _effectiveBackground(Color? current, Color? inherited) {
  return current ?? inherited;
}

TextStyle _ensureReadableTextStyle(TextStyle style, Color? backgroundColor) {
  final color = style.color;
  if (color == null) return style;
  return style.copyWith(color: _ensureReadableColor(color, backgroundColor));
}

Color _ensureReadableColor(Color color, Color? backgroundColor) {
  if (backgroundColor == null || backgroundColor.a < 1) return color;
  if (_contrastRatio(color, backgroundColor) >= 4.5) return color;

  final blackContrast = _contrastRatio(Colors.black, backgroundColor);
  final whiteContrast = _contrastRatio(Colors.white, backgroundColor);
  return blackContrast >= whiteContrast ? Colors.black : Colors.white;
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = math.max(foregroundLuminance, backgroundLuminance);
  final darker = math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

double? _parseCssSize(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text.isEmpty || text == 'auto' || text.endsWith('%')) return null;
  final match = RegExp(r'^(-?\d+(?:\.\d+)?)(px|em|rem)?$').firstMatch(text);
  if (match == null) return null;
  final number = double.tryParse(match.group(1)!);
  if (number == null) return null;
  final unit = match.group(2);
  return switch (unit) {
    'em' || 'rem' => number * 16,
    _ => number,
  };
}

FontWeight? _parseFontWeight(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text == 'bold') return FontWeight.w700;
  final numeric = int.tryParse(text);
  if (numeric == null) return null;
  return FontWeight.values[math.min(8, math.max(0, (numeric ~/ 100) - 1))];
}

double? _parseLineHeight(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text.endsWith('px')) return null;
  return double.tryParse(text);
}

TextAlign? _parseTextAlign(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'center' => TextAlign.center,
    'right' => TextAlign.right,
    'justify' => TextAlign.justify,
    _ => null,
  };
}

TextDecoration? _parseTextDecoration(Map<String, String> style) {
  final value = style['text-decoration-line'] ?? style['text-decoration'];
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text.isEmpty) return null;
  if (text == 'none') return TextDecoration.none;

  final decorations = <TextDecoration>[];
  if (text.contains('underline')) decorations.add(TextDecoration.underline);
  if (text.contains('line-through')) {
    decorations.add(TextDecoration.lineThrough);
  }
  if (text.contains('overline')) decorations.add(TextDecoration.overline);
  if (decorations.isEmpty) return null;
  return TextDecoration.combine(decorations);
}

TextDecorationStyle? _parseTextDecorationStyle(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'double' => TextDecorationStyle.double,
    'dotted' => TextDecorationStyle.dotted,
    'dashed' => TextDecorationStyle.dashed,
    'wavy' => TextDecorationStyle.wavy,
    'solid' => TextDecorationStyle.solid,
    _ => null,
  };
}

List<_GridColumn> _parseGridTemplateColumns(String? value) {
  if (value == null) return const [];
  final columns = <_GridColumn>[];
  for (final rawPart in value.trim().toLowerCase().split(RegExp(r'\s+'))) {
    if (rawPart.isEmpty) continue;
    if (rawPart == 'auto') {
      columns.add(const _GridColumn.auto());
      continue;
    }
    if (rawPart.endsWith('fr')) {
      final flex = double.tryParse(rawPart.substring(0, rawPart.length - 2));
      if (flex == null || flex <= 0) return const [];
      columns.add(_GridColumn.flex(flex));
      continue;
    }
    final width = _parseCssSize(rawPart);
    if (width == null) return const [];
    columns.add(_GridColumn.fixed(width));
  }
  return columns;
}

CrossAxisAlignment _crossAxisAlignmentForAlignItems(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'center' => CrossAxisAlignment.center,
    'end' || 'flex-end' => CrossAxisAlignment.end,
    'stretch' => CrossAxisAlignment.stretch,
    _ => CrossAxisAlignment.start,
  };
}

class _GridColumn {
  const _GridColumn.auto() : flex = null, width = null;

  const _GridColumn.flex(double value) : flex = value, width = null;

  const _GridColumn.fixed(double value) : flex = null, width = value;

  final double? flex;
  final double? width;

  Widget wrap(Widget child) {
    final fixedWidth = width;
    if (fixedWidth != null) return SizedBox(width: fixedWidth, child: child);

    final flexValue = flex;
    if (flexValue != null) {
      return Expanded(
        flex: math.max(1, (flexValue * 1000).round()),
        child: child,
      );
    }

    return child;
  }
}

String _normalizeText(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

const Set<String> _inlineTags = {
  'a',
  'b',
  'br',
  'code',
  'em',
  'i',
  'small',
  'span',
  'strong',
};
