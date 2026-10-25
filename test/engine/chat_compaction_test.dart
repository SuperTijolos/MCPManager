import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/agent/context_budget.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/settings/app_settings.dart';

import '../support/fakes.dart';

List<LlmEvent> _reply(String text, {int? promptTokens}) => [
  LlmTextDelta(text),
  LlmDone(promptTokens: promptTokens, completionTokens: 10),
];

Future<ProviderContainer> _setup(ScriptedLlm llm, {int? context}) async {
  final c = await makeContainer(llm: llm);
  addTearDown(c.dispose);
  if (context != null) {
    final settings = c.read(llmSettingsProvider);
    c
        .read(llmSettingsProvider.notifier)
        .upsert(settings.activeProvider!.copyWith(contextLength: context));
  }
  return c;
}

List<NoticeItem> _notices(ProviderContainer c) =>
    c.read(chatControllerProvider).items.whereType<NoticeItem>().toList();

void main() {
  test(
    'a long conversation is summarized before the window overflows',
    () async {
      // A window this small is full as soon as three turns exist.
      final llm = ScriptedLlm([
        _reply('first answer', promptTokens: 900),
        _reply('second answer'),
        [
          const LlmTextDelta('Summary: the user asked about one.'),
          const LlmDone(),
        ],
        _reply('third answer', promptTokens: 1800),
      ]);
      final c = await _setup(llm, context: 2048);
      final chat = c.read(chatControllerProvider.notifier);

      await chat.send('one');
      await chat.send('two');
      expect(_notices(c).where((n) => n.text.contains('Summarized')), isEmpty);
      await chat.send('three');

      final notices = _notices(c).map((n) => n.text);
      expect(
        notices.where((t) => t.contains('Summarized earlier messages')),
        hasLength(1),
      );
      // The request that followed the summary carries it, then the kept turns.
      final sent = llm.received.last;
      expect(isCompactionSummary(sent[1]), isTrue);
      expect(sent[1].content, contains('the user asked about one'));
      expect(sent.map((m) => m.content), contains('two'));
      expect(sent.map((m) => m.content), contains('three'));
      expect(sent.map((m) => m.content), isNot(contains('one')));

      // What you see is untouched: the whole transcript is still there.
      final shown = c.read(chatControllerProvider).items;
      expect(shown.whereType<UserItem>().map((u) => u.text), [
        'one',
        'two',
        'three',
      ]);
      // The notice sits before the reply it made room for.
      final items = c.read(chatControllerProvider).items;
      final noticeAt = items.indexWhere(
        (i) => i is NoticeItem && i.text.contains('Summarized'),
      );
      final replyAt = items.indexWhere(
        (i) => i is AssistantItem && i.text == 'third answer',
      );
      expect(noticeAt, lessThan(replyAt));
    },
  );

  test('the meter learns the window and the last prompt size', () async {
    final llm = ScriptedLlm([_reply('hi', promptTokens: 1234)]);
    final c = await _setup(llm, context: 8192);
    expect((c.read(chatControllerProvider)).contextUsed, isNull);

    await c.read(chatControllerProvider.notifier).send('hello');

    final state = c.read(chatControllerProvider);
    expect(state.contextUsed, 1234);
    expect(state.contextLimit, 8192);
  });

  test('automatic compaction can be switched off', () async {
    final llm = ScriptedLlm([_reply('a'), _reply('b'), _reply('c')]);
    final c = await _setup(llm, context: 2048);
    c
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(autoCompact: false));
    final chat = c.read(chatControllerProvider.notifier);

    await chat.send('one');
    await chat.send('two');
    await chat.send('three');

    expect(llm.received, hasLength(3), reason: 'no summary request');
    expect(llm.received.last.where(isCompactionSummary), isEmpty);
    expect(_notices(c).where((n) => n.text.contains('Summarized')), isEmpty);
  });

  test('a tool list too big for the window is called out once', () async {
    final llm = ScriptedLlm([_reply('a'), _reply('b')]);
    final c = await _setup(llm, context: 2048);
    final chat = c.read(chatControllerProvider.notifier);

    await chat.send('one');
    await chat.send('two');

    final warnings = _notices(c).where((n) => n.text.contains('tool list'));
    expect(warnings, hasLength(1));
    expect(warnings.single.text, contains('Hide tools'));
  });

  test('no warning when the window is roomy', () async {
    final llm = ScriptedLlm([_reply('a')]);
    final c = await _setup(llm, context: 200000);
    await c.read(chatControllerProvider.notifier).send('one');
    expect(_notices(c), isEmpty);
  });

  test(
    '"compact now" summarizes by hand, and says so when it is early',
    () async {
      final llm = ScriptedLlm([
        _reply('a'),
        _reply('b'),
        _reply('c'),
        [const LlmTextDelta('Manual summary.'), const LlmDone()],
      ]);
      final c = await _setup(llm, context: 200000);
      final chat = c.read(chatControllerProvider.notifier);

      await chat.send('one');
      await chat.compactNow();
      expect(_notices(c).last.text, contains('Nothing to compact'));

      await chat.send('two');
      await chat.send('three');
      await chat.compactNow();

      expect(_notices(c).last.text, contains('Summarized earlier messages'));
      expect(c.read(chatControllerProvider).running, isFalse);
      await chat.send('four'); // scripted turns are used up: a bare reply
      final sent = llm.received.last;
      expect(isCompactionSummary(sent[1]), isTrue);
      expect(sent[1].content, contains('Manual summary.'));
    },
  );

  test('notices are saved with the conversation', () async {
    final llm = ScriptedLlm([_reply('a')]);
    final c = await _setup(llm, context: 2048);
    await c.read(chatControllerProvider.notifier).send('one');
    expect(_notices(c), isNotEmpty);

    final id = c.read(chatControllerProvider).activeId!;
    c.read(chatControllerProvider.notifier).newConversation();
    await c.read(chatControllerProvider.notifier).open(id);

    expect(_notices(c), isNotEmpty);
  });

  test('streamed text is shown in bursts but arrives complete', () async {
    final words = [for (var i = 0; i < 300; i++) 'w$i '];
    final llm = ScriptedLlm([
      [for (final w in words) LlmTextDelta(w), const LlmDone()],
    ]);
    final c = await _setup(llm, context: 200000);
    var updates = 0;
    c.listen(chatControllerProvider, (_, _) => updates++);

    await c.read(chatControllerProvider.notifier).send('go');

    final reply = c
        .read(chatControllerProvider)
        .items
        .whereType<AssistantItem>()
        .single;
    expect(reply.text, words.join());
    expect(updates, lessThan(60), reason: '300 tokens, far fewer rebuilds');
  });
}
