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

    test('uses native rendering for static grid cards', () {
      final html = sanitizeHtmlFragment(_gridCardHtml);

      expect(classifyHtmlFragment(html), HtmlFragmentRenderMode.nativeSimple);
    });

    test('uses native rendering for expanded safe static CSS', () {
      final html = sanitizeHtmlFragment(_expandedSafeCssHtml);

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

    test('falls back to WebView for style values with URLs', () {
      const html =
          '<div style="cursor:url(https://example.com/a.cur), auto">Card</div>';

      expect(classifyHtmlFragment(html), HtmlFragmentRenderMode.webView);
    });
  });
}

const String _gridCardHtml =
    '<div style="border:1px solid #d0d0d0;border-radius:12px;padding:18px;'
    'margin:16px 0;background:#fafafa;color:#222;font-family:system-ui;">'
    '<div style="font-size:18px;font-weight:700;margin-bottom:12px;">'
    'RoPE core operation'
    '</div>'
    '<div style="display:grid;grid-template-columns:1fr auto 1fr;gap:14px;'
    'align-items:center;">'
    '<div style="border:1px solid #bbb;border-radius:10px;padding:14px;'
    'background:white;">Original vector</div>'
    '<div style="font-size:28px;color:#555;">-&gt;</div>'
    '<div style="border:1px solid #bbb;border-radius:10px;padding:14px;'
    'background:white;">Rotated vector</div>'
    '</div>'
    '</div>';

const String _expandedSafeCssHtml =
    '<div style="box-sizing:border-box;min-width:120px;max-width:420px;'
    'min-height:40px;max-height:220px;opacity:.96;box-shadow:0 2px 8px '
    'rgba(0,0,0,.14);border-bottom:1px solid #ddd;padding:12px;">'
    '<span style="text-decoration:underline;text-decoration-color:#555;'
    'text-decoration-style:solid;overflow-wrap:anywhere;word-break:break-word;'
    'white-space:normal;">Safe CSS card</span>'
    '</div>';
