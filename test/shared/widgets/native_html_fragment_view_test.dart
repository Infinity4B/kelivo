import 'package:Kelivo/shared/widgets/html_fragment_parser.dart';
import 'package:Kelivo/shared/widgets/native_html_fragment_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NativeHtmlFragmentView', () {
    testWidgets('renders simple inline HTML without a WebView', (tester) async {
      await tester.pumpWidget(
        _host(
          NativeHtmlFragmentView(
            fragment: _fragment('<div>Hello <strong>World</strong></div>'),
          ),
        ),
      );

      expect(_richTextContaining('Hello World'), findsOneWidget);
    });

    testWidgets('renders static grid cards natively', (tester) async {
      await tester.pumpWidget(
        _host(NativeHtmlFragmentView(fragment: _fragment(_gridCardHtml))),
      );

      expect(_richTextContaining('RoPE core operation'), findsOneWidget);
      expect(_richTextContaining('Original vector'), findsOneWidget);
      expect(_richTextContaining('Rotated vector'), findsOneWidget);
      expect(find.byType(Row), findsWidgets);
    });

    testWidgets('updates data-role content when a data-step button is tapped', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          NativeHtmlFragmentView(
            fragment: _fragment(
              '<div data-html-interaction-id="card">'
              '<div data-role="title">Old title</div>'
              '<div data-role="desc">Old desc</div>'
              '<button data-step="one">One</button>'
              '<button data-step="two">Two</button>'
              '</div>'
              '<script type="application/json">'
              '{"one":{"title":"First title","desc":"First desc"},'
              '"two":{"title":"Second title","desc":"Second desc"}}'
              '</script>',
              allowEventHandlers: true,
            ),
            enableDeclarativeInteractions: true,
          ),
        ),
      );

      expect(find.text('First title'), findsOneWidget);
      expect(find.text('First desc'), findsOneWidget);

      await tester.tap(find.text('Two'));
      await tester.pump();

      expect(find.text('Second title'), findsOneWidget);
      expect(find.text('Second desc'), findsOneWidget);
      expect(find.text('First title'), findsNothing);
      expect(find.text('First desc'), findsNothing);
    });
  });
}

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

HtmlFragment _fragment(String rawHtml, {bool allowEventHandlers = false}) {
  return HtmlFragment(
    index: 0,
    rawHtml: rawHtml,
    sanitizedHtml: sanitizeHtmlFragment(
      rawHtml,
      allowEventHandlers: allowEventHandlers,
    ),
    complete: true,
  );
}

Finder _richTextContaining(String text) {
  return find.byWidgetPredicate((widget) {
    return widget is RichText && widget.text.toPlainText().contains(text);
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
