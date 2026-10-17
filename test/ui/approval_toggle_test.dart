import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'the composer switches the open chat between asking and automatic',
    (tester) async {
      final container = await pumpApp(tester);
      await goTo(tester, '/chat');

      expect(find.text('Ask first'), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);
      expect(container.read(chatControllerProvider).autoApprove, isFalse);

      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();
      expect(container.read(chatControllerProvider).autoApprove, isTrue);
      expect(
        tester
            .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .selected,
        {true},
      );

      await tester.tap(find.text('Ask first'));
      await tester.pumpAndSettle();
      expect(container.read(chatControllerProvider).autoApprove, isFalse);
    },
  );

  testWidgets('the toggle fits a phone width', (tester) async {
    await pumpApp(tester, size: const Size(360, 740));
    await goTo(tester, '/chat');
    expect(tester.takeException(), isNull);
    expect(find.text('Automatic'), findsOneWidget);
  });
}
