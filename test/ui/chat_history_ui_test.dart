import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/agent/chat_store.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

ScriptedLlm _llm() => ScriptedLlm([
  for (var i = 1; i <= 10; i++) [LlmTextDelta('reply $i'), const LlmDone()],
]);

Future<ProviderContainer> _seeded(WidgetTester tester, {Size? size}) async {
  final c = await pumpApp(
    tester,
    llm: _llm(),
    size: size ?? const Size(1280, 900),
  );
  final chat = c.read(chatControllerProvider.notifier);
  await chat.send('Why did the deploy fail?');
  chat.newConversation();
  await chat.send('List my servers');
  chat.newConversation();
  await chat.send('Clean up old tools');
  await goTo(tester, '/chat');
  return c;
}

void main() {
  group('historyGroup', () {
    final now = DateTime(2026, 10, 17, 15);
    test('buckets by age', () {
      expect(historyGroup(DateTime(2026, 10, 17, 1), now), 'Today');
      expect(historyGroup(DateTime(2026, 10, 16, 23), now), 'Yesterday');
      expect(historyGroup(DateTime(2026, 10, 12), now), 'Previous 7 days');
      expect(historyGroup(DateTime(2026, 10, 1), now), 'Previous 30 days');
      expect(historyGroup(DateTime(2026, 8, 1), now), 'Older');
    });
  });

  group('operator history', () {
    testWidgets(
      'the panel lists conversations, newest first, under a date heading',
      (tester) async {
        await _seeded(tester);
        expect(find.text('Today'), findsOneWidget);
        final titles = [
          'Clean up old tools',
          'List my servers',
          'Why did the deploy fail?',
        ];
        // Titles also appear in the open chat; the panel has each one.
        for (final t in titles) {
          expect(find.text(t), findsWidgets);
        }
        final y = [
          for (final t in titles) tester.getTopLeft(find.text(t).first).dy,
        ];
        expect(y, orderedEquals([...y]..sort()), reason: 'newest at the top');
        expect(find.text('New conversation'), findsWidgets);
      },
    );

    testWidgets('clicking a conversation opens it, with its messages', (
      tester,
    ) async {
      final c = await _seeded(tester);
      expect(find.text('Clean up old tools'), findsWidgets);

      await tester.tap(find.text('Why did the deploy fail?').first);
      await tester.pumpAndSettle();

      final items = c.read(chatControllerProvider).items;
      expect(
        items.whereType<UserItem>().single.text,
        'Why did the deploy fail?',
      );
      expect(find.text('reply 1'), findsOneWidget);
      expect(find.text('reply 3'), findsNothing);
    });

    testWidgets('New conversation starts empty and keeps the old one listed', (
      tester,
    ) async {
      final c = await _seeded(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'New conversation'));
      await tester.pumpAndSettle();
      expect(c.read(chatControllerProvider).items, isEmpty);
      expect(c.read(chatControllerProvider).conversations, hasLength(3));
      expect(find.text('Operator'), findsWidgets);
    });

    testWidgets('search filters the list', (tester) async {
      await _seeded(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Search conversations'),
        'servers',
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'List my servers'), findsOneWidget);
      expect(
        find.widgetWithText(ListTile, 'Why did the deploy fail?'),
        findsNothing,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Search conversations'),
        'zzz',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('rename and delete from the menu', (tester) async {
      final c = await _seeded(tester);
      final menus = find.byTooltip('Conversation actions');
      await tester.tap(menus.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Tool cleanup',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();
      expect(
        c.read(chatControllerProvider).conversations.first.title,
        'Tool cleanup',
      );

      await tester.tap(find.byTooltip('Conversation actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('removed from this browser'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(c.read(chatControllerProvider).conversations, hasLength(2));
    });

    testWidgets('delete all asks first', (tester) async {
      final c = await _seeded(tester);
      await tester.tap(find.text('Delete all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(c.read(chatControllerProvider).conversations, hasLength(3));

      await tester.tap(find.text('Delete all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete all'));
      await tester.pumpAndSettle();
      expect(c.read(chatControllerProvider).conversations, isEmpty);
      expect(find.text('Your conversations will appear here.'), findsOneWidget);
    });

    testWidgets('the panel can be hidden and shown again on wide screens', (
      tester,
    ) async {
      await _seeded(tester);
      expect(find.text('Search conversations'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide history'));
      await tester.pumpAndSettle();
      expect(find.text('Search conversations'), findsNothing);
      await tester.tap(find.byTooltip('Show history'));
      await tester.pumpAndSettle();
      expect(find.text('Search conversations'), findsOneWidget);
    });

    testWidgets(
      'on a phone the history opens as a sheet and closes after picking',
      (tester) async {
        final c = await _seeded(tester, size: const Size(400, 800));
        expect(find.text('Search conversations'), findsNothing);

        await tester.tap(find.byTooltip('Conversation history'));
        await tester.pumpAndSettle();
        expect(find.text('Search conversations'), findsOneWidget);

        await tester.tap(find.widgetWithText(ListTile, 'List my servers'));
        await tester.pumpAndSettle();
        expect(
          find.text('Search conversations'),
          findsNothing,
          reason: 'sheet closed',
        );
        expect(
          c
              .read(chatControllerProvider)
              .items
              .whereType<UserItem>()
              .single
              .text,
          'List my servers',
        );
      },
    );

    testWidgets('an empty history says so', (tester) async {
      await pumpApp(tester);
      await goTo(tester, '/chat');
      expect(find.text('Your conversations will appear here.'), findsOneWidget);
    });
  });
}
