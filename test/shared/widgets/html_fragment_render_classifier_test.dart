import 'package:Kelivo/shared/widgets/html_fragment_parser.dart';
import 'package:Kelivo/shared/widgets/html_fragment_render_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyHtmlFragment', () {
    test('uses native rendering for simple supported HTML', () {
      final html = sanitizeHtmlFragment(
        '<div style="padding:12px; border-radius:10px">'
        '<strong>Title</strong><p>Body</p>'
        '</div>',
      );

      expect(classifyHtmlFragment(html), HtmlFragmentRenderMode.nativeSimple);
    });

    test('uses native interaction for data-step JSON cards', () {
      final html = sanitizeHtmlFragment(
        '<div data-html-interaction-id="card">'
        '<div data-role="title">Old</div>'
        '<div data-role="desc">Old desc</div>'
        '<button data-step="one" style="cursor:pointer">One</button>'
        '</div>'
        '<script type="application/json">'
        '{"one":{"title":"New","desc":"New desc"}}'
        '</script>',
        allowEventHandlers: true,
      );

      expect(
        classifyHtmlFragment(html),
        HtmlFragmentRenderMode.nativeInteractive,
      );
    });

    test('falls back to WebView for executable scripts', () {
      final html = sanitizeHtmlFragment(
        '<div>Card</div><script>window.ok = true;</script>',
        allowEventHandlers: true,
      );

      expect(classifyHtmlFragment(html), HtmlFragmentRenderMode.webView);
    });

    test('falls back to WebView for unsupported tags and styles', () {
      final unsupportedTag = sanitizeHtmlFragment('<svg><rect /></svg>');
      final unsupportedStyle = sanitizeHtmlFragment(
        '<div style="position:absolute">Card</div>',
      );

      expect(
        classifyHtmlFragment(unsupportedTag),
        HtmlFragmentRenderMode.webView,
      );
      expect(
        classifyHtmlFragment(unsupportedStyle),
        HtmlFragmentRenderMode.webView,
      );
    });
  });
}
