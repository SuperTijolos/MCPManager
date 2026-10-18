import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/context_budget.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';

import '../support/fakes.dart';

/// A provider whose summary request fails.
class _FailingLlm extends ScriptedLlm {
  _FailingLlm() : super(const []);

  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) async* {
    throw LlmException('model unavailable');
  }
}

/// One user turn: the question, a tool call, its result and the answer.
List<LlmMessage> _turn(int n, {int resultChars = 200, String? thinking}) => [
  LlmMessage.user('question $n'),
  LlmMessage.assistant(
    '',
    thinking: thinking,
    toolCalls: [LlmToolCall(id: 'c$n', name: 'Demo__lookup')],
  ),
  LlmMessage.tool(
    '<tool_output name="lookup">\n${'r' * resultChars}\n</tool_output>',
    toolCallId: 'c$n',
    toolName: 'Demo__lookup',
  ),
  LlmMessage.assistant('answer $n'),
];

ContextCompactor _compactor(LlmProvider llm, {int window = 8000}) =>
    ContextCompactor(provider: llm, model: 'gemma4', contextTokens: window);

void main() {
  group('estimates', () {
    test('count roughly one token per 3.5 characters', () {
      expect(estimateTokens(''), 0);
      expect(estimateTokens('a' * 350), 100);
    });

    test('messages add their reasoning and tool calls', () {
      final plain = estimateMessageTokens(const LlmMessage.assistant('hi'));
      final rich = estimateMessageTokens(
        LlmMessage.assistant(
          'hi',
          thinking: 'long thought ' * 20,
          toolCalls: [
            LlmToolCall(id: 'a', name: 'tool', arguments: {'x': 1}),
          ],
        ),
      );
      expect(rich, greaterThan(plain + 50));
    });
  });

  group('ContextCompactor', () {
    test('leaves a conversation that fits alone', () async {
      final llm = ScriptedLlm([]);
      final history = [..._turn(1), ..._turn(2), ..._turn(3)];
      final before = List.of(history);

      final result = await _compactor(llm)
          .ensureFits(history, fixedTokens: 500);

      expect(result, isNull);
      expect(history, before);
      expect(llm.received, isEmpty);
    });

    test(
      'shortens old results and reasoning first, without the model',
      () async {
        final llm = ScriptedLlm([]);
        final history = [
          ..._turn(1, resultChars: 30000, thinking: 'old thoughts ' * 50),
          ..._turn(2),
          ..._turn(3),
        ];
        final recent = history.sublist(4);

        final result = await _compactor(llm)
            .ensureFits(history, fixedTokens: 500);

        expect(result!.kind, CompactionKind.shortened);
        expect(result.tokensAfter, lessThan(result.tokensBefore));
        expect(llm.received, isEmpty, reason: 'no summary was needed');
        final oldResult = history[2];
        expect(oldResult.content.length, lessThan(1000));
        expect(oldResult.content, contains('characters removed'));
        expect(oldResult.content, endsWith('</tool_output>'));
        expect(history[1].thinking, isNull);
        expect(
          history.sublist(4),
          recent,
          reason: 'recent turns are untouched',
        );
      },
    );

    test('summarizes older turns when shortening is not enough', () async {
      final llm = ScriptedLlm([
        [const LlmTextDelta('The user asked 1 and 2.'), const LlmDone()],
      ]);
      final history = [
        ..._turn(1, resultChars: 12000),
        ..._turn(2, resultChars: 12000),
        ..._turn(3, resultChars: 6000),
        ..._turn(4, resultChars: 6000),
      ];
      final keptTail = history.sublist(8);

      final result = await _compactor(llm)
          .ensureFits(history, fixedTokens: 500);

      expect(result!.kind, CompactionKind.summarized);
      expect(isCompactionSummary(history[0]), isTrue);
      expect(history[0].content, contains('The user asked 1 and 2.'));
      expect(history[1].role, LlmRole.assistant);
      expect(history[2].content, 'question 3');
      expect(history.sublist(2), keptTail, reason: 'the last two turns stay');
      expect(llm.received.single.first.role, LlmRole.system);
      expect(llm.received.single.last.content, contains('question 1'));
      expect(llm.toolSpecs.single, isEmpty);
    });

    test('drops older turns when the summary cannot be written', () async {
      final history = [
        ..._turn(1, resultChars: 12000),
        ..._turn(2, resultChars: 12000),
        ..._turn(3, resultChars: 6000),
        ..._turn(4, resultChars: 6000),
      ];
      final keptTail = history.sublist(8);

      final result = await _compactor(_FailingLlm())
          .ensureFits(history, fixedTokens: 500);

      expect(result!.kind, CompactionKind.trimmed);
      expect(history.first.role, LlmRole.user);
      expect(history.first.content, 'question 3');
      expect(history, keptTail);
    });

    test('a forced pass summarizes even a conversation that fits', () async {
      final llm = ScriptedLlm([
        [const LlmTextDelta('Short summary.'), const LlmDone()],
      ]);
      final history = [..._turn(1), ..._turn(2), ..._turn(3)];

      final result = await _compactor(llm)
          .ensureFits(history, fixedTokens: 500, force: true);

      expect(result!.kind, CompactionKind.summarized);
      expect(isCompactionSummary(history.first), isTrue);
      expect(history[2].content, 'question 2');
    });

    test('a forced pass has nothing to do with one or two turns', () async {
      final llm = ScriptedLlm([]);
      final history = [..._turn(1), ..._turn(2)];
      final result = await _compactor(llm)
          .ensureFits(history, fixedTokens: 500, force: true);
      expect(result, isNull);
      expect(history, hasLength(8));
    });

    test('an earlier summary is folded into the next one', () async {
      final llm = ScriptedLlm([
        [const LlmTextDelta('First summary.'), const LlmDone()],
        [const LlmTextDelta('Second summary.'), const LlmDone()],
      ]);
      final history = [for (var n = 1; n <= 4; n++) ..._turn(n)];
      final compactor = _compactor(llm);

      await compactor.ensureFits(history, fixedTokens: 0, force: true);
      history.addAll(_turn(5));
      await compactor.ensureFits(history, fixedTokens: 0, force: true);

      expect(history.first.content, contains('Second summary.'));
      expect(
        history.where(isCompactionSummary),
        hasLength(1),
        reason: 'the old summary is replaced, not stacked',
      );
      expect(
        llm.received.last.last.content,
        contains('First summary.'),
        reason: 'the second pass saw the first summary',
      );
    });

    test('measured token counts make it compact sooner', () {
      final compactor = _compactor(ScriptedLlm([]));
      final history = [..._turn(1, resultChars: 12000), ..._turn(2)];
      expect(compactor.needsCompaction(history, 0), isFalse);

      final estimated = estimateHistoryTokens(history);
      for (var i = 0; i < 6; i++) {
        compactor.calibrate(actual: estimated * 2, estimated: estimated);
      }
      expect(compactor.needsCompaction(history, 0), isTrue);
    });
  });
}
