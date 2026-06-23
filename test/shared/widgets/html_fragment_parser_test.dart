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
      expect(
        result.segments[1].fragment!.rawHtml,
        '<div class="card">Card</div>',
      );
      expect(result.segments[1].fragment!.sanitizedHtml, contains('Card'));
      expect(result.segments[2].text, '\nAfter');
    });

    test('splits fragments wrapped by escaped HTML comment markers', () {
      final result = parseHtmlFragmentSegments(
        'Before\n&lt;!-- html-render-start --&gt;<div>Card</div>'
        '&lt;!-- html-render-end --&gt;\nAfter',
      );

      expect(result.hasHtml, isTrue);
      expect(result.segments, hasLength(3));
      expect(result.segments[0].text, 'Before\n');
      expect(result.segments[1].fragment!.complete, isTrue);
      expect(result.segments[1].fragment!.sanitizedHtml, '<div>Card</div>');
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

    test('keeps simple inline handlers only for complete fragments', () {
      final complete = parseHtmlFragmentSegments(
        '$htmlFragmentMarkerStart'
        '<button onclick="this.textContent=\'Done\'">Tap</button>'
        '$htmlFragmentMarkerEnd',
      );
      final streaming = parseHtmlFragmentSegments(
        '$htmlFragmentMarkerStart'
        '<button onclick="this.textContent=\'Done\'">Tap</button>',
        streaming: true,
      );

      expect(complete.segments.single.fragment!.complete, isTrue);
      expect(
        complete.segments.single.fragment!.sanitizedHtml,
        contains('onclick'),
      );
      expect(streaming.segments.single.fragment!.complete, isFalse);
      expect(
        streaming.segments.single.fragment!.sanitizedHtml,
        isNot(contains('onclick')),
      );
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

    test('unwraps full HTML documents while keeping body content', () {
      final sanitized = sanitizeHtmlFragment(
        '<!doctype html><html><head><style>.bad{}</style></head>'
        '<body><div>Card</div></body></html>',
      );

      expect(sanitized, contains('<div>Card</div>'));
      expect(sanitized, isNot(contains('<html')));
      expect(sanitized, isNot(contains('<body')));
      expect(sanitized, isNot(contains('<style')));
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

    test('can keep event handlers while still filtering unsafe URLs', () {
      final sanitized = sanitizeHtmlFragment(
        '<button onclick="this.textContent=\'Done\'">Tap</button>'
        '<a href="javascript:alert(1)" onmouseover="this.textContent=\'x\'">Link</a>'
        '<div srcdoc="<p>x</p>">Bad</div>',
        allowEventHandlers: true,
      );

      expect(sanitized, contains('onclick'));
      expect(sanitized, contains('onmouseover'));
      expect(sanitized, isNot(contains('javascript:')));
      expect(sanitized, isNot(contains('srcdoc')));
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

    test('keeps valid JSON interaction scripts without explicit target', () {
      final sanitized = sanitizeHtmlFragment(
        '<div data-html-interaction-id="card">Card</div>'
        '<script type="application/json">'
        '{"checkpoint":{"title":"T","desc":"D"}}'
        '</script>',
      );

      expect(sanitized, contains('data-html-interaction-id="card"'));
      expect(sanitized, contains('type="application/json"'));
      expect(sanitized, contains('checkpoint'));
    });

    test(
      'strips executable scripts but keeps JSON data scripts for previews',
      () {
        final sanitized = sanitizeHtmlFragment(
          '<div>Card</div>'
          '<button onclick="bad()">Tap</button>'
          '<script>window.ran = true;</script>'
          '<script type="application/json" data-html-interaction-for="card">'
          '{"enabled":true}'
          '</script>',
          allowEventHandlers: true,
        );

        final stripped = stripExecutableScriptsFromHtmlFragment(sanitized);

        expect(stripped, contains('<div>Card</div>'));
        expect(stripped, isNot(contains('window.ran')));
        expect(stripped, isNot(contains('onclick')));
        expect(stripped, contains('application/json'));
      },
    );
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
      expect(document, contains("post('wheel'"));
      expect(document, contains('capture: true'));
      expect(document, contains('html-fragment-content'));
      expect(document, isNot(contains("post('width'")));
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

    test('injects theme variables and contrast repair for dark mode', () {
      final document = buildHtmlFragmentDocument(
        sanitizedHtml: '<div style="background:white">Card</div>',
        colorScheme: ColorScheme.dark(),
        allowUserScripts: true,
      );

      expect(document, contains('color-scheme: dark'));
      expect(document, contains('--kelivo-fg'));
      expect(document, contains('--kelivo-control-bg'));
      expect(document, contains('function fixContrast'));
      expect(document, contains('new MutationObserver(function ()'));
    });

    test('injects JSON data-step interaction hydration', () {
      final sanitized = sanitizeHtmlFragment(
        '<div data-html-interaction-id="demo">'
        '<div data-role="title">Old</div>'
        '<div data-role="desc">Old desc</div>'
        '<button data-step="checkpoint">Checkpoint</button>'
        '</div>'
        '<script type="application/json">'
        '{"checkpoint":{"title":"New","desc":"New desc"}}'
        '</script>',
        allowEventHandlers: true,
      );

      final document = buildHtmlFragmentDocument(
        sanitizedHtml: sanitized,
        colorScheme: colorScheme,
        allowUserScripts: true,
      );

      expect(document, contains('function hydrateJsonInteractions'));
      expect(document, contains('data-step'));
      expect(document, contains('data-role="title"'));
      expect(document, contains('New desc'));
    });
  });
}
