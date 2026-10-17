import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/agent/chat_store.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';

import '../support/fakes.dart';

ScriptedLlm _llm([int answers = 6]) => ScriptedLlm([
  for (var i = 0; i < answers; i++)
    [LlmTextDelta('answer ${i + 1}'), const LlmDone()],
]);

Future<ProviderContainer> _container(
  ScriptedLlm llm, {
  Map<String, Object> prefs = const {},
}) async {
  final c = await makeContainer(llm: llm, prefs: prefs);
  addTearDown(c.dispose);
  return c;
}

Map<String, Object> _carry(ProviderContainer c) {
  final sp = c.read(sharedPreferencesProvider);
  return {
    for (final k in sp.getKeys())
      if (k.startsWith('mcpm.chat')) k: sp.get(k)!,
  };
}

void main() {
  test('a conversation appears in the history as soon as you send, titled from the first prompt', () async {
    final c = await _container(_llm());
    final chat = c.read(chatControllerProvider.notifier);
    expect(c.read(chatControllerProvider).conversations, isEmpty);

    await chat.send(
      'How many servers are connected right now?\nAnd their tools?',
    );

    final state = c.read(chatControllerProvider);
    expect(state.conversations, hasLength(1));
    expect(
      state.conversations.single.title,
      'How many servers are connected right now?',
    );
    expect(state.conversations.single.messageCount, 1);
    expect(state.activeId, state.conversations.single.id);
  });

  test('long prompts get a short title', () {
    expect(titleFromPrompt('x' * 100).length, 49);
    expect(titleFromPrompt('   '), 'New conversation');
  });

  test(
    'new conversation keeps the old one; each has its own model context',
    () async {
      final llm = _llm();
      final c = await _container(llm);
      final chat = c.read(chatControllerProvider.notifier);

      await chat.send('first topic');
      final firstId = c.read(chatControllerProvider).activeId!;

      chat.newConversation();
      expect(c.read(chatControllerProvider).items, isEmpty);
      expect(c.read(chatControllerProvider).activeId, isNull);
      expect(c.read(chatControllerProvider).conversations, hasLength(1));

      await chat.send('second topic');
      final state = c.read(chatControllerProvider);
      expect(state.conversations, hasLength(2));
      expect(
        state.conversations.first.title,
        'second topic',
        reason: 'most recent first',
      );
      // The second conversation's model never saw the first one.
      final seen = llm.received.last
          .where((m) => m.role == LlmRole.user)
          .map((m) => m.content);
      expect(seen, ['second topic']);

      chat.open(firstId);
      expect(
        c.read(chatControllerProvider).items.whereType<UserItem>().single.text,
        'first topic',
      );
      await chat.send('back to the first');
      final replayed = llm.received.last
          .where((m) => m.role == LlmRole.user)
          .map((m) => m.content);
      expect(replayed, [
        'first topic',
        'back to the first',
      ], reason: 'its own context was restored');
    },
  );

  test(
    'opening a conversation moves it to the top once you continue it',
    () async {
      final c = await _container(_llm());
      final chat = c.read(chatControllerProvider.notifier);
      await chat.send('one');
      final oneId = c.read(chatControllerProvider).activeId!;
      chat.newConversation();
      await chat.send('two');
      expect(c.read(chatControllerProvider).conversations.map((m) => m.title), [
        'two',
        'one',
      ]);

      chat.open(oneId);
      await chat.send('one again');
      expect(
        c.read(chatControllerProvider).conversations.map((m) => m.title).first,
        'one',
      );
      expect(
        c.read(chatControllerProvider).conversations.first.messageCount,
        2,
      );
    },
  );

  test('rename and delete', () async {
    final c = await _container(_llm());
    final chat = c.read(chatControllerProvider.notifier);
    await chat.send('one');
    final id = c.read(chatControllerProvider).activeId!;

    chat.rename(id, '  Server cleanup  ');
    expect(
      c.read(chatControllerProvider).conversations.single.title,
      'Server cleanup',
    );
    chat.rename(id, '   ');
    expect(
      c.read(chatControllerProvider).conversations.single.title,
      'Server cleanup',
      reason: 'blank ignored',
    );

    // Deleting the open conversation empties the view; the content is gone from storage.
    chat.delete(id);
    final state = c.read(chatControllerProvider);
    expect(state.items, isEmpty);
    expect(state.activeId, isNull);
    expect(state.conversations, isEmpty);
    expect(
      c.read(sharedPreferencesProvider).getString('mcpm.chat.$id.v1'),
      isNull,
    );
  });

  test('deleting another conversation leaves the open one alone', () async {
    final c = await _container(_llm());
    final chat = c.read(chatControllerProvider.notifier);
    await chat.send('old');
    final oldId = c.read(chatControllerProvider).activeId!;
    chat.newConversation();
    await chat.send('current');
    final currentId = c.read(chatControllerProvider).activeId!;

    chat.delete(oldId);
    final state = c.read(chatControllerProvider);
    expect(state.activeId, currentId);
    expect(state.items.whereType<UserItem>().single.text, 'current');
    expect(state.conversations.map((m) => m.id), [currentId]);
  });

  test('delete all', () async {
    final c = await _container(_llm());
    final chat = c.read(chatControllerProvider.notifier);
    await chat.send('a');
    chat.newConversation();
    await chat.send('b');
    chat.deleteAll();
    expect(c.read(chatControllerProvider).conversations, isEmpty);
    expect(c.read(chatControllerProvider).items, isEmpty);
    final sp = c.read(sharedPreferencesProvider);
    expect(
      sp.getKeys().where(
        (k) => RegExp(r'^mcpm\.chat\.chat_.*\.v1$').hasMatch(k),
      ),
      isEmpty,
    );
  });

  test('the history and the open conversation survive a restart', () async {
    final first = await _container(_llm());
    final chat = first.read(chatControllerProvider.notifier);
    await chat.send('alpha');
    chat.newConversation();
    await chat.send('beta');

    final second = await _container(_llm(), prefs: _carry(first));
    final state = second.read(chatControllerProvider);
    expect(state.conversations.map((m) => m.title), ['beta', 'alpha']);
    expect(
      state.items.whereType<UserItem>().single.text,
      'beta',
      reason: 'reopens where you left off',
    );
  });

  test('starting a new conversation survives a restart too (you come back to an empty chat)', () async {
    final first = await _container(_llm());
    final chat = first.read(chatControllerProvider.notifier);
    await chat.send('alpha');
    chat.newConversation();

    final second = await _container(_llm(), prefs: _carry(first));
    expect(second.read(chatControllerProvider).items, isEmpty);
    expect(second.read(chatControllerProvider).conversations, hasLength(1));
  });

  test('switching away from a running conversation stops it cleanly', () async {
    final c = await _container(
      ScriptedLlm([
        [
          LlmToolCallsEvent(const [
            LlmToolCall(
              id: 'c1',
              name: 'mcpm_remove_server',
              arguments: {'server': 'x'},
            ),
          ]),
        ],
      ]),
    );
    final chat = c.read(chatControllerProvider.notifier);
    final run = chat.send('remove x'); // waits for approval
    await pumpEventQueue();
    expect(c.read(chatControllerProvider).running, isTrue);

    chat.newConversation();
    await run;
    expect(c.read(chatControllerProvider).running, isFalse);
    expect(c.read(chatControllerProvider).items, isEmpty);
    expect(
      c.read(chatControllerProvider).conversations,
      hasLength(1),
      reason: 'the stopped one is kept',
    );
  });

  test('the number of kept conversations is bounded', () async {
    final c = await _container(_llm(maxConversations + 5));
    final chat = c.read(chatControllerProvider.notifier);
    for (var i = 0; i < maxConversations + 3; i++) {
      await chat.send('topic $i');
      chat.newConversation();
    }
    final list = c.read(chatControllerProvider).conversations;
    expect(list, hasLength(maxConversations));
    expect(list.first.title, 'topic ${maxConversations + 2}');
    expect(
      list.any((m) => m.title == 'topic 0'),
      isFalse,
      reason: 'the oldest were dropped',
    );
  });

  test(
    'the single conversation of the first version is migrated into the list',
    () async {
      final legacy = jsonEncode({
        'items': [
          {'type': 'user', 'id': 'u1', 'text': 'my old question'},
          {
            'type': 'assistant',
            'id': 'a1',
            'text': 'my old answer',
            'thinking': '',
          },
        ],
        'history': [
          {'role': 'user', 'content': 'my old question'},
          {'role': 'assistant', 'content': 'my old answer'},
        ],
      });
      final c = await _container(_llm(), prefs: {'mcpm.chat.v1': legacy});
      final state = c.read(chatControllerProvider);
      expect(state.conversations.single.title, 'my old question');
      expect(
        c.read(sharedPreferencesProvider).getString('mcpm.chat.v1'),
        isNull,
        reason: 'migrated once',
      );

      final chat = c.read(chatControllerProvider.notifier);
      chat.open(state.conversations.single.id);
      expect(
        c
            .read(chatControllerProvider)
            .items
            .whereType<AssistantItem>()
            .single
            .text,
        'my old answer',
      );
    },
  );

  test('a missing or corrupt conversation body does not crash', () async {
    final first = await _container(_llm());
    await first.read(chatControllerProvider.notifier).send('x');
    final id = first.read(chatControllerProvider).activeId!;
    final prefs = _carry(first)..['mcpm.chat.$id.v1'] = '{not json';

    final second = await _container(_llm(), prefs: prefs);
    expect(second.read(chatControllerProvider).items, isEmpty);
    expect(second.read(chatControllerProvider).conversations, hasLength(1));
  });
}
