import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/ui/widgets.dart';

void main() {
  testWidgets(
    'scrolling chat tool output does not trigger scrollbar assertions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 200,
                child: CodeBlock(
                  List.generate(80, (i) => 'Tool output line $i').join('\n'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar).first);
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollbar.controller, same(scrollView.controller));
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -150),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}
