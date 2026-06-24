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
