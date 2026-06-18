import 'package:Kelivo/shared/widgets/html_fragment_parser.dart';
import 'package:Kelivo/shared/widgets/html_fragment_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHtmlFragmentSegments', () {
    test('splits markdown and complete marked HTML fragments', () {
      final result = parseHtmlFragmentSegments(
        'Before\n$htmlFragmentMarkerStart<div class="card">Card</div>'
        '$htmlFragmentMarkerEnd\nAfter',
      );

      expect(result.hasHtml, isTrue);
      expect(result.segments, hasLength(3));
      expect(result.segments[0].text, 'Before\n');
      expect(result.segments[1].fragment!.complete, isTrue);
      expect(result.segments[1].fragment!.rawHtml, '<div class="card">Card</div>');
      expect(result.segments[1].fragment!.sanitizedHtml, contains('Card'));
      expect(result.segments[2].text, '\nAfter');
    });

    test('keeps an unmatched marker as markdown when not streaming', () {
      final result = parseHtmlFragmentSegments(
        'Before\n$htmlFragmentMarkerStart<div>Draft</div>',
      );

      expect(result.hasHtml, isFalse);
      expect(result.segments, hasLength(1));
      expect(result.segments.single.text, contains(htmlFragmentMarkerStart));
    });

    test('emits an incomplete fragment for streaming unmatched marker', () {
      final result = parseHtmlFragmentSegments(
        'Before\n$htmlFragmentMarkerStart<div>Draft</div>',
        streaming: true,
      );

      expect(result.hasHtml, isTrue);
      expect(result.segments, hasLength(2));
      expect(result.segments[1].fragment!.complete, isFalse);
      expect(result.segments[1].fragment!.sanitizedHtml, contains('Draft'));
    });

    test('stops parsing after the configured fragment limit', () {
      final result = parseHtmlFragmentSegments(
        '$htmlFragmentMarkerStart<div>One</div>$htmlFragmentMarkerEnd'
        '$htmlFragmentMarkerStart<div>Two</div>$htmlFragmentMarkerEnd',
        maxFragments: 1,
      );

      expect(result.segments.where((segment) => segment.isHtml), hasLength(1));
      expect(result.segments.last.text, contains('Two'));
    });
  });

  group('sanitizeHtmlFragment', () {
    test('decodes entities and removes forbidden tags', () {
      final sanitized = sanitizeHtmlFragment(
        '&lt;div&gt;Safe&lt;/div&gt;<iframe src="https://example.com"></iframe>',
      );

      expect(sanitized, contains('<div>Safe</div>'));
      expect(sanitized, isNot(contains('iframe')));
    });

    test('removes event handlers, srcdoc, and unsafe URLs', () {
      final sanitized = sanitizeHtmlFragment(
        '<a href="javascript:alert(1)" onclick="alert(1)">Link</a>'
        '<img srcdoc="<p>x</p>" src="data:text/html,evil">',
      );

      expect(sanitized, isNot(contains('javascript:')));
      expect(sanitized, isNot(contains('onclick')));
      expect(sanitized, isNot(contains('srcdoc')));
      expect(sanitized, isNot(contains('data:text/html')));
    });

    test('removes unsafe style rules while keeping simple declarations', () {
      final sanitized = sanitizeHtmlFragment(
        '<div style="color:red; background:url(javascript:alert(1)); width:10px">'
        'Styled'
        '</div>',
      );

      expect(sanitized, contains('color:red'));
      expect(sanitized, contains('width:10px'));
      expect(sanitized, isNot(contains('url(')));
    });

    test('keeps inline executable scripts without unsafe attributes', () {
      final sanitized = sanitizeHtmlFragment(
        '<script type="text/javascript" onclick="bad()">window.ok = true;</script>'
        '<script src="https://example.com/app.js"></script>',
      );

      expect(sanitized, contains('window.ok = true;'));
      expect(sanitized, contains('type="text/javascript"'));
      expect(sanitized, isNot(contains('onclick')));
      expect(sanitized, isNot(contains('src=')));
      expect(sanitized, isNot(contains('app.js')));
    });

    test('keeps valid JSON interaction scripts', () {
      final sanitized = sanitizeHtmlFragment(
        '<script type="application/json" data-html-interaction-for="card.1">'
        '{"enabled":true}'
        '</script>',
      );

      expect(sanitized, contains('type="application/json"'));
      expect(sanitized, contains('data-html-interaction-for="card.1"'));
      expect(sanitized, contains('{"enabled":true}'));
    });

    test('strips executable scripts but keeps JSON data scripts for previews', () {
      final sanitized = sanitizeHtmlFragment(
        '<div>Card</div>'
        '<script>window.ran = true;</script>'
        '<script type="application/json" data-html-interaction-for="card">'
        '{"enabled":true}'
        '</script>',
      );

      final stripped = stripExecutableScriptsFromHtmlFragment(sanitized);

      expect(stripped, contains('<div>Card</div>'));
      expect(stripped, isNot(contains('window.ran')));
      expect(stripped, contains('application/json'));
    });
  });

  group('buildHtmlFragmentDocument', () {
    final colorScheme = ColorScheme.light();

    test('omits executable scripts when user scripts are disabled', () {
      final sanitized = sanitizeHtmlFragment(
        '<div>Card</div><script>window.ran = true;</script>',
      );

      final document = buildHtmlFragmentDocument(
        sanitizedHtml: sanitized,
        colorScheme: colorScheme,
        allowUserScripts: false,
      );

      expect(document, contains('<div>Card</div>'));
      expect(document, isNot(contains('window.ran = true')));
      expect(document, contains('HtmlFragmentHost'));
    });

    test('keeps executable scripts when user scripts are enabled', () {
      final sanitized = sanitizeHtmlFragment(
        '<div>Card</div><script>window.ran = true;</script>',
      );

      final document = buildHtmlFragmentDocument(
        sanitizedHtml: sanitized,
        colorScheme: colorScheme,
        allowUserScripts: true,
      );

      expect(document, contains('<div>Card</div>'));
      expect(document, contains('window.ran = true'));
    });
  });
}
