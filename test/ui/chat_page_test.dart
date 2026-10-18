import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/llm/provider_config.dart';
import 'package:mcp_manager/engine/settings/app_settings.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

List<LlmEvent> _reply(String text, {int? promptTokens}) => [
  LlmTextDelta(text),
  LlmDone(promptTokens: promptTokens),
];

Future<ProviderContainer> _open(
  WidgetTester tester, {
  ScriptedLlm? llm,
  Size size = const Size(1280, 900),
}) async {
  final c = await pumpApp(tester, llm: llm, size: size);
  await goTo(tester, '/chat');
  return c;
}

/// The picker's own list; the page behind it shows the active model too.
Finder _inPicker(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  testWidgets('the page and its navigation entry are called Chat', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Chat with your tools'), findsOneWidget);
    expect(find.text('Operator'), findsNothing);
  });

  group('model picker', () {
    Future<ProviderContainer> openWithModels(WidgetTester tester) async {
      final c = await _open(tester);
      final settings = c.read(llmSettingsProvider);
      final notifier = c.read(llmSettingsProvider.notifier);
      notifier.upsert(
        settings.activeProvider!.copyWith(
          models: ['gemma4', 'qwen3.5:4b', 'llama3.2'],
        ),
      );
      notifier.upsert(
        const ProviderConfig(
          id: 'or',
          name: 'OpenRouter',
          kind: ProviderKind.openaiCompatible,
          baseUrl: 'https://openrouter.ai/api/v1',
          models: [
            'nvidia/nemotron-3-super-120b-a12b:free',
            'qwen/qwen3-coder:free',
            'anthropic/claude-haiku',
          ],
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('lists every model with a search box', (tester) async {
      await openWithModels(tester);
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();

      expect(find.text('Choose model'), findsWidgets);
      expect(find.text('Search 6 models'), findsOneWidget);
      expect(_inPicker('qwen3.5:4b'), findsOneWidget);
      expect(
        _inPicker('nvidia/nemotron-3-super-120b-a12b:free'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('searching narrows by model or provider name', (tester) async {
      await openWithModels(tester);
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'qwen');
      await tester.pumpAndSettle();
      expect(_inPicker('qwen3.5:4b'), findsOneWidget);
      expect(_inPicker('qwen/qwen3-coder:free'), findsOneWidget);
      expect(_inPicker('llama3.2'), findsNothing);

      await tester.enterText(find.byType(TextField).last, 'openrouter free');
      await tester.pumpAndSettle();
      expect(_inPicker('qwen/qwen3-coder:free'), findsOneWidget);
      expect(_inPicker('anthropic/claude-haiku'), findsNothing);
      expect(_inPicker('gemma4'), findsNothing);

      await tester.enterText(find.byType(TextField).last, 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No matching models'), findsOneWidget);
    });

    testWidgets('picking a model switches provider and model', (tester) async {
      final c = await openWithModels(tester);
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'haiku');
      await tester.pumpAndSettle();
      await tester.tap(find.text('anthropic/claude-haiku'));
      await tester.pumpAndSettle();

      final settings = c.read(llmSettingsProvider);
      expect(settings.activeProviderId, 'or');
      expect(settings.activeModel, 'anthropic/claude-haiku');
      expect(find.text('Choose model'), findsNothing, reason: 'dialog closed');
    });

    testWidgets('very long model names do not overflow', (tester) async {
      await openWithModels(tester);
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('works on a phone-sized screen', (tester) async {
      await _open(tester, size: const Size(390, 800));
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();
      expect(find.text('Choose model'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('long conversations', () {
    testWidgets('stay pinned to the newest message and only build what shows', (
      tester,
    ) async {
      final llm = ScriptedLlm([
        for (var i = 1; i <= 40; i++) _reply('reply number $i'),
      ]);
      final c = await _open(tester, llm: llm);
      final chat = c.read(chatControllerProvider.notifier);
      for (var i = 1; i <= 40; i++) {
        await chat.send('question $i');
      }
      await tester.pumpAndSettle();

      expect(find.text('reply number 40'), findsOneWidget);
      expect(find.text('question 40'), findsOneWidget);
      expect(
        find.text('reply number 1'),
        findsNothing,
        reason: 'old messages are not built until you scroll to them',
      );

      await tester.drag(find.byType(ListView).last, const Offset(0, 6000));
      await tester.pumpAndSettle();
      expect(find.text('reply number 40'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sending jumps back to the newest message', (tester) async {
      final llm = ScriptedLlm([
        for (var i = 1; i <= 30; i++) _reply('reply number $i'),
      ]);
      final c = await _open(tester, llm: llm);
      final chat = c.read(chatControllerProvider.notifier);
      for (var i = 1; i <= 29; i++) {
        await chat.send('question $i');
      }
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, 6000));
      await tester.pumpAndSettle();
      expect(find.text('reply number 29'), findsNothing);

      await tester.enterText(find.byType(TextField).last, 'one more');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(find.text('reply number 30'), findsOneWidget);
    });

    testWidgets('unchanged messages are not rebuilt when the chat updates', (
      tester,
    ) async {
      final llm = ScriptedLlm([
        for (var i = 1; i <= 8; i++) _reply('**answer** number $i'),
      ]);
      final c = await _open(tester, llm: llm);
      final chat = c.read(chatControllerProvider.notifier);
      for (var i = 1; i <= 8; i++) {
        await chat.send('question $i');
      }
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownBody), findsWidgets);

      var markdownRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is MarkdownBody) markdownRebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      // Every one of these re-renders the page, like a streamed token does.
      for (var i = 0; i < 6; i++) {
        chat.setAutoApprove(i.isEven);
        await tester.pump();
      }

      expect(markdownRebuilds, 0);
    });

    testWidgets('a streamed reply renders next to the earlier answers', (
      tester,
    ) async {
      final llm = ScriptedLlm([
        _reply('an earlier answer'),
        [for (var i = 0; i < 50; i++) LlmTextDelta('t$i '), const LlmDone()],
      ]);
      final c = await _open(tester, llm: llm);
      final chat = c.read(chatControllerProvider.notifier);
      await chat.send('first');
      await chat.send('second');
      await tester.pumpAndSettle();

      expect(find.text('an earlier answer'), findsOneWidget);
      expect(find.textContaining('t49'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('compaction in the UI', () {
    testWidgets('the compact button waits for a conversation', (tester) async {
      final c = await _open(tester, llm: ScriptedLlm([_reply('hello')]));
      final button = find.byKey(const ValueKey('compact-conversation'));
      expect(tester.widget<IconButton>(button).onPressed, isNull);

      await c.read(chatControllerProvider.notifier).send('hi');
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing to compact yet'), findsOneWidget);
    });

    testWidgets('the context meter appears once a reply reports its size', (
      tester,
    ) async {
      final c = await _open(
        tester,
        llm: ScriptedLlm([_reply('hello', promptTokens: 4096)]),
      );
      expect(find.byKey(const ValueKey('context-meter')), findsNothing);

      await c.read(chatControllerProvider.notifier).send('hi');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('context-meter')), findsOneWidget);
      expect(find.text('4.1k / 16k'), findsOneWidget);
    });

    testWidgets('notices from the app are shown between messages', (
      tester,
    ) async {
      final c = await _open(
        tester,
        llm: ScriptedLlm([_reply('a'), _reply('b')]),
      );
      c
          .read(llmSettingsProvider.notifier)
          .upsert(
            c
                .read(llmSettingsProvider)
                .activeProvider!
                .copyWith(contextLength: 2048),
          );
      await c.read(chatControllerProvider.notifier).send('hi');
      await tester.pumpAndSettle();

      expect(find.textContaining('tool list alone take'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the automatic option is in Settings and defaults on', (
      tester,
    ) async {
      final c = await _open(tester);
      expect(c.read(appSettingsProvider).autoCompact, isTrue);

      await goTo(tester, '/settings');
      await tester.tap(find.widgetWithText(ListTile, 'Operator').first);
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('auto-compact-switch'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(c.read(appSettingsProvider).autoCompact, isFalse);
    });
  });
}
