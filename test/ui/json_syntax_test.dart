import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/ui/json_syntax.dart';
import 'package:mcp_manager/ui/widgets.dart';

void main() {
  test('lexer highlights JSON types while preserving every character', () {
    const source =
        '{"name": "value with \\"quotes\\"", "num": -12.5e+3, '
        '"active": true, "missing": null, "off": false}';
    final spans = JsonSyntax.spans(source);
    expect(spans.map((span) => span.text).join(), source);
    expect(
      spans.where((span) => span.text == '"name"').single.style?.color,
      JsonSyntax.key,
    );
    expect(
      spans
          .where((span) => span.text == '"value with \\"quotes\\""')
          .single
          .style
          ?.color,
      JsonSyntax.string,
    );
    expect(
      spans.where((span) => span.text == '-12.5e+3').single.style?.color,
      JsonSyntax.number,
    );
    for (final literal in ['true', 'false', 'null']) {
      expect(
        spans.where((span) => span.text == literal).single.style?.color,
        JsonSyntax.literal,
      );
    }
  });

  test('lexer tolerates unfinished JSON and escaped strings', () {
    for (final source in [
      '{',
      '{"incomplete',
      '{"a": 1,',
      '{"a": "unfinished\\',
      'tru',
      '',
    ]) {
      expect(JsonSyntax.spans(source).map((span) => span.text).join(), source);
    }
    expect(
      JsonSyntax.spans('"falsehood"').single.style?.color,
      JsonSyntax.string,
    );
    expect(JsonSyntax.spans('truefalse').single.style?.color, isNull);
  });

  testWidgets(
    'editable JSON uses highlighted text but preserves selection and typing',
    (tester) async {
      final controller = JsonEditingController(text: '{"a": 1}');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: controller, maxLines: 4)),
        ),
      );
      expect(
        controller
            .buildTextSpan(
              context: tester.element(find.byType(TextField)),
              withComposing: true,
            )
            .children!
            .any((span) => span.style?.color == JsonSyntax.key),
        isTrue,
      );
      controller.selection = const TextSelection.collapsed(offset: 5);
      expect(controller.selection.baseOffset, 5);
      await tester.enterText(find.byType(TextField), '{"valid": true}');
      await tester.pump();
      expect(controller.text, '{"valid": true}');
      expect(
        controller
            .buildTextSpan(
              context: tester.element(find.byType(TextField)),
              withComposing: true,
            )
            .toPlainText(),
        controller.text,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'JSON read-only code blocks expose highlighted selectable spans',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CodeBlock('{"answer": 42}', json: true)),
        ),
      );
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan, isNotNull);
      expect(selectable.textSpan!.toPlainText(), '{"answer": 42}');
      expect(
        selectable.textSpan!.children!.any(
          (span) => span.style?.color == JsonSyntax.key,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
