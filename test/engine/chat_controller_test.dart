import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/agent/operator_agent.dart';
import 'package:mcp_manager/engine/agent/toolbox.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/fakes.dart';

final _tools = [
  {
    'name': 'lookup',
    'description': 'Read something',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'q': {'type': 'string'},
      },
    },
    'annotations': {'readOnlyHint': true},
  },
  {
    'name': 'delete_all',
    'description': 'Destroys things',
    'inputSchema': {'type': 'object', 'properties': {}},
  },
];

/// Counts how many times the destructive tool really ran on the server.
int _deleteRuns = 0;

FakeMcpServer _server() => FakeMcpServer(
  tools: _tools,
  handlers: {
    'lookup': (args) => textResult('found ${args['q']}'),
    'delete_all': (_) {
      _deleteRuns++;
      return textResult('deleted');
    },
  },
);

LlmToolCallsEvent _call(
  String id,
  String name, [
  Map<String, dynamic> args = const {},
]) => LlmToolCallsEvent([LlmToolCall(id: id, name: name, arguments: args)]);

/// Connects a "Demo" server and returns a container wired to [llm].
Future<ProviderContainer> _setup(
  LlmProvider llm, {
  FakeMcpServer? server,
}) async {
  final container = await makeContainer(server: server ?? _server(), llm: llm);
  addTearDown(container.dispose);
  await container
      .read(mcpHubProvider.notifier)
      .addServer(name: 'Demo', url: 'https://mcp.test/mcp');
  container.read(auditLogProvider.notifier).clear();
  return container;
}

List<ToolItem> _toolItems(ProviderContainer c) =>
    c.read(chatControllerProvider).items.whereType<ToolItem>().toList();

void main() {
  setUp(() => _deleteRuns = 0);

  test(
    'read-only tools run without approval and the answer streams back',
    () async {
      final llm = ScriptedLlm([
        [
          _call('c1', 'Demo__lookup', {'q': 'gemma'}),
        ],
        [
          const LlmTextDelta('It says '),
          const LlmTextDelta('found gemma.'),
          const LlmDone(),
        ],
      ]);
      final container = await _setup(llm);

      await container
          .read(chatControllerProvider.notifier)
          .send('look up gemma');

      final state = container.read(chatControllerProvider);
      expect(state.running, isFalse);
      final tool = _toolItems(container).single;
      expect(tool.status, ToolStatus.done);
      expect(tool.output, 'found gemma');
      final answer = state.items.whereType<AssistantItem>().last;
      expect(answer.text, 'It says found gemma.');

      // The model saw the result wrapped as untrusted data.
      final secondTurn = llm.received[1];
      expect(secondTurn.last.role, LlmRole.tool);
      expect(
        secondTurn.last.content,
        startsWith('<tool_output name="Demo__lookup">'),
      );
      expect(secondTurn.last.content, contains('found gemma'));
      // The system prompt tells the model to distrust tool output.
      expect(secondTurn.first.role, LlmRole.system);
      expect(secondTurn.first.content, contains('untrusted'));

      final audit = container.read(auditLogProvider).single;
      expect(audit.source, AuditSource.operator);
      expect(audit.actor, 'operator:gemma4');
      expect(audit.approval, 'auto');
      expect(audit.toolName, 'lookup');
    },
  );

  test('unannotated tools wait for approval, then run and are audited as user-approved', () async {
    final llm = ScriptedLlm([
      [_call('c1', 'Demo__delete_all')],
      [const LlmTextDelta('Done.'), const LlmDone()],
    ]);
    final container = await _setup(llm);
    final controller = container.read(chatControllerProvider.notifier);

    final run = controller.send('clean up');
    await pumpEventQueue();

    expect(_toolItems(container).single.status, ToolStatus.awaitingApproval);
    expect(
      container.read(auditLogProvider),
      isEmpty,
      reason: 'nothing may execute before approval',
    );
    expect(_deleteRuns, 0);

    controller.decide('c1', ApprovalDecision.approveOnce);
    await run;

    expect(_deleteRuns, 1);

    expect(_toolItems(container).single.status, ToolStatus.done);
    final audit = container.read(auditLogProvider).single;
    expect(audit.status, AuditStatus.success);
    expect(audit.approval, 'user');
  });

  test('denied calls never execute, are audited, and the model is told not to retry', () async {
    final llm = ScriptedLlm([
      [_call('c1', 'Demo__delete_all')],
      [const LlmTextDelta('Okay, I will not.'), const LlmDone()],
    ]);
    final container = await _setup(llm);
    final controller = container.read(chatControllerProvider.notifier);

    final run = controller.send('clean up');
    await pumpEventQueue();
    controller.decide('c1', ApprovalDecision.deny);
    await run;

    expect(_deleteRuns, 0, reason: 'a denied call must never reach the server');
    expect(_toolItems(container).single.status, ToolStatus.denied);
    final audit = container.read(auditLogProvider).single;
    expect(audit.status, AuditStatus.denied);
    expect(audit.approval, 'denied');
    expect(audit.result, isNull);
    expect(llm.received[1].last.content, contains('denied'));
  });

  test(
    '"always allow" skips approval for later calls in the same conversation',
    () async {
      final llm = ScriptedLlm([
        [_call('c1', 'Demo__delete_all')],
        [_call('c2', 'Demo__delete_all')],
        [const LlmTextDelta('Both done.'), const LlmDone()],
      ]);
      final container = await _setup(llm);
      final controller = container.read(chatControllerProvider.notifier);

      final run = controller.send('twice');
      await pumpEventQueue();
      controller.decide('c1', ApprovalDecision.approveSession);
      await run;

      final tools = _toolItems(container);
      expect(tools.map((t) => t.status), [ToolStatus.done, ToolStatus.done]);
      expect(_deleteRuns, 2);
      final approvals = container
          .read(auditLogProvider)
          .reversed
          .map((e) => e.approval)
          .toList();
      expect(approvals, ['session', 'session']);
    },
  );

  test(
    'unknown tool names are reported to the model instead of crashing',
    () async {
      final llm = ScriptedLlm([
        [_call('c1', 'does_not_exist')],
        [const LlmTextDelta('Sorry.'), const LlmDone()],
      ]);
      final container = await _setup(llm);
      await container.read(chatControllerProvider.notifier).send('hi');

      expect(_toolItems(container).single.status, ToolStatus.error);
      expect(llm.received[1].last.content, contains('Unknown tool'));
      expect(container.read(chatControllerProvider).running, isFalse);
    },
  );

  test(
    'platform tools answer questions about the app itself without approval',
    () async {
      final llm = ScriptedLlm([
        [_call('c1', 'mcpm_list_servers')],
        [const LlmTextDelta('One server.'), const LlmDone()],
      ]);
      final container = await _setup(llm);
      await container
          .read(chatControllerProvider.notifier)
          .send('what servers?');

      final tool = _toolItems(container).single;
      expect(tool.status, ToolStatus.done);
      expect(tool.output, contains('Demo'));
      expect(tool.output, contains('connected'));
    },
  );

  test('stopping while a call awaits approval cancels it and rolls the history back', () async {
    final llm = ScriptedLlm([
      [_call('c1', 'Demo__delete_all')],
      [const LlmTextDelta('hello again'), const LlmDone()],
    ]);
    final container = await _setup(llm);
    final controller = container.read(chatControllerProvider.notifier);

    final run = controller.send('clean up');
    await pumpEventQueue();
    controller.stop();
    await run;

    expect(container.read(chatControllerProvider).running, isFalse);
    expect(_deleteRuns, 0);

    // A fresh question must not carry the half-finished tool exchange.
    await controller.send('and now?');
    final second = llm.received[1];
    expect(
      second.map((m) => m.role),
      [LlmRole.system, LlmRole.user, LlmRole.user],
      reason: 'the prompt stays, but no assistant tool_calls without a matching tool result',
    );
    expect(second[1].content, 'clean up');
    expect(second.last.content, 'and now?');
    expect(
      container
          .read(chatControllerProvider)
          .items
          .whereType<AssistantItem>()
          .last
          .text,
      'hello again',
    );
  });

  test(
    'model errors are shown in the chat and the controller stays usable',
    () async {
      final llm = _FlakyLlm();
      final container = await _setup(llm);
      final controller = container.read(chatControllerProvider.notifier);

      await controller.send('first');
      var state = container.read(chatControllerProvider);
      expect(state.running, isFalse);
      expect(
        state.items.whereType<ErrorItem>().single.message,
        contains('connection refused'),
      );
      expect(
        llm.closed,
        isTrue,
        reason: 'the provider client is released after each run',
      );

      await controller.send('second');
      state = container.read(chatControllerProvider);
      expect(state.items.whereType<AssistantItem>().last.text, 'recovered');
      // The failed turn left no assistant output behind; both prompts are replayed.
      final replayed = llm.history.last.where((m) => m.role != LlmRole.system);
      expect(replayed.map((m) => (m.role, m.content)), [
        (LlmRole.user, 'first'),
        (LlmRole.user, 'second'),
      ]);
    },
  );

  test('clear resets the conversation and allowances', () async {
    final llm = ScriptedLlm([
      [const LlmTextDelta('hi'), const LlmDone()],
    ]);
    final container = await _setup(llm);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.send('hello');
    expect(container.read(chatControllerProvider).items, isNotEmpty);

    controller.clear();
    expect(container.read(chatControllerProvider).items, isEmpty);
  });

  test('duplicate and awkward tool names are made unique and valid', () async {
    final container = await makeContainer(
      server: FakeMcpServer(
        tools: [
          {
            'name': 'do thing!',
            'inputSchema': {'type': 'object'},
          },
        ],
      ),
    );
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    await hub.addServer(name: 'My Server', url: 'https://a.test/mcp');
    await hub.addServer(name: 'My Server', url: 'https://b.test/mcp');

    final names = container.read(llmToolboxProbe).map((t) => t.name).toList();
    final mcpNames = names.where((n) => !n.startsWith('mcpm_')).toList();
    expect(mcpNames, hasLength(2));
    expect(mcpNames.toSet(), hasLength(2));
    for (final n in mcpNames) {
      expect(RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(n), isTrue, reason: n);
    }
  });
}

/// Fails on the first call, then answers normally.
class _FlakyLlm implements LlmProvider {
  final history = <List<LlmMessage>>[];
  bool closed = false;

  @override
  Future<List<LlmModel>> listModels() async => const [];

  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) async* {
    history.add(List.of(messages));
    if (history.length == 1) throw LlmException('connection refused');
    yield const LlmTextDelta('recovered');
    yield const LlmDone();
  }

  @override
  void close() => closed = true;
}

final llmToolboxProbe = Provider((ref) => buildToolbox(ref));
