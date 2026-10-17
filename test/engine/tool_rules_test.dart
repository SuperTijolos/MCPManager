import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/agent/operator_agent.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/rules/tool_rules.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';
import 'package:mcp_manager/engine/settings/app_settings.dart';

import '../support/fakes.dart';

const _server = McpServerConfig(
  id: 's1',
  name: 'Docs',
  url: 'https://d.test/mcp',
);
const _other = McpServerConfig(
  id: 's2',
  name: 'Shell',
  url: 'https://s.test/mcp',
);

McpTool _tool(
  String name, {
  Map<String, dynamic> props = const {},
  List<String> required = const [],
  String? description = 'Does a thing.',
  bool readOnly = false,
}) => McpTool(
  name: name,
  description: description,
  inputSchema: {
    'type': 'object',
    'properties': props,
    if (required.isNotEmpty) 'required': required,
  },
  annotations: readOnly ? {'readOnlyHint': true} : {},
);

ToolRule _rule(
  String name,
  List<RuleArg> args, {
  RuleScope scope = RuleScope.all,
  List<String> serverIds = const [],
  List<String> toolKeys = const [],
  List<RuleCondition> conditions = const [],
  MatchMode mode = MatchMode.any,
  bool enabled = true,
  String instructions = '',
}) => ToolRule(
  id: name,
  name: name,
  args: args,
  scope: scope,
  serverIds: serverIds,
  toolKeys: toolKeys,
  conditions: conditions,
  matchMode: mode,
  enabled: enabled,
  instructions: instructions,
);

const _reason = RuleArg(name: 'reason', description: 'Why.', required: true);

void main() {
  group('matching', () {
    final read = _tool('read_file');
    final write = _tool('write_file', description: 'Writes a file to disk');

    test('scope all matches every tool; servers narrow it', () {
      expect(_rule('r', []).matches(_server, read), isTrue);
      expect(_rule('r', [], serverIds: ['s1']).matches(_server, read), isTrue);
      expect(_rule('r', [], serverIds: ['s1']).matches(_other, read), isFalse);
    });

    test('explicit tool scope matches only those tools', () {
      final r = _rule(
        'r',
        [],
        scope: RuleScope.tools,
        toolKeys: ['s1/write_file'],
      );
      expect(r.matches(_server, write), isTrue);
      expect(r.matches(_server, read), isFalse);
      expect(
        r.matches(_other, write),
        isFalse,
        reason: 'same name, other server',
      );
    });

    test('conditions: operators, fields and any/all', () {
      RuleCondition c(
        ConditionOp op,
        String v, [
        ConditionField f = ConditionField.name,
      ]) => RuleCondition(field: f, op: op, value: v);
      bool m(
        List<RuleCondition> cs, [
        MatchMode mode = MatchMode.any,
        McpTool? t,
      ]) => _rule(
        'r',
        [],
        conditions: cs,
        mode: mode,
      ).matches(_server, t ?? write);

      expect(
        m([c(ConditionOp.contains, 'WRITE')]),
        isTrue,
        reason: 'case-insensitive',
      );
      expect(m([c(ConditionOp.equals, 'write_file')]), isTrue);
      expect(m([c(ConditionOp.equals, 'write')]), isFalse);
      expect(m([c(ConditionOp.glob, 'write_*')]), isTrue);
      expect(m([c(ConditionOp.glob, '*_file')]), isTrue);
      expect(m([c(ConditionOp.glob, 'w?ite_file')]), isTrue);
      expect(m([c(ConditionOp.glob, 'read_*')]), isFalse);
      expect(m([c(ConditionOp.regex, r'^(read|write)_file$')]), isTrue);
      expect(
        m([c(ConditionOp.regex, '(')]),
        isFalse,
        reason: 'invalid regex never matches',
      );
      expect(
        m([c(ConditionOp.contains, 'disk', ConditionField.description)]),
        isTrue,
      );
      expect(m([c(ConditionOp.equals, 'docs', ConditionField.server)]), isTrue);

      final yes = c(ConditionOp.contains, 'write');
      final no = c(ConditionOp.contains, 'zzz');
      expect(m([yes, no], MatchMode.any), isTrue);
      expect(m([yes, no], MatchMode.all), isFalse);
      expect(m([yes, yes], MatchMode.all), isTrue);
    });

    test('an empty condition value does not exclude anything', () {
      expect(
        _rule(
          'r',
          [],
          conditions: [const RuleCondition(value: '  ')],
        ).matches(_server, read),
        isTrue,
      );
    });
  });

  group('effective tool', () {
    test('extra arguments appear in the schema; the original is untouched', () {
      final tool = _tool(
        't',
        props: {
          'q': {'type': 'string'},
        },
        required: ['q'],
      );
      final before = jsonEncode(tool.inputSchema);
      final e = computeEffective(_server, tool, [
        _rule('Reason', [_reason, const RuleArg(name: 'expected_result')]),
      ], null);

      final props = e.inputSchema['properties'] as Map;
      expect(props.keys, containsAll(['q', 'reason', 'expected_result']));
      expect(props['reason'], {'type': 'string', 'description': 'Why.'});
      expect(e.inputSchema['required'], ['q', 'reason']);
      expect(e.rules, ['Reason']);
      expect(e.isModified, isTrue);
      expect(
        jsonEncode(tool.inputSchema),
        before,
        reason: 'the discovered schema is never mutated',
      );
    });

    test('an argument the server already defines is not overridden by a custom one', () {
      final tool = _tool(
        't',
        props: {
          'reason': {'type': 'integer'},
        },
      );
      final e = computeEffective(_server, tool, [
        _rule('R', [_reason]),
      ], null);
      expect(e.extras, isEmpty);
      expect(e.warnings.single, contains('clashes'));
      expect((e.inputSchema['properties'] as Map)['reason'], {
        'type': 'integer',
      });
    });

    test('hard-coded values hide the argument from the model', () {
      final tool = _tool(
        't',
        props: {
          'workspace': {'type': 'string'},
          'q': {'type': 'string'},
        },
        required: ['workspace', 'q'],
      );
      final e = computeEffective(_server, tool, [
        _rule('Pin', [
          const RuleArg(
            name: 'workspace',
            source: ArgSource.hardcoded,
            fixedValue: 'dev',
          ),
        ]),
      ], null);
      expect((e.inputSchema['properties'] as Map).keys, ['q']);
      expect(e.inputSchema['required'], ['q']);
      expect(e.fixed.single.arg.name, 'workspace');
    });

    test('the earlier rule wins when two define the same argument', () {
      final first = _rule('First', [
        const RuleArg(name: 'reason', description: 'from first'),
      ]);
      final second = _rule('Second', [
        const RuleArg(name: 'reason', description: 'from second'),
      ]);
      final e = computeEffective(_server, _tool('t'), [first, second], null);
      expect(e.extras.single.rule, 'First');
      expect(
        (e.inputSchema['properties'] as Map)['reason']['description'],
        'from first',
      );
      expect(e.rules, ['First', 'Second']);
    });

    test('disabled and non-matching rules are ignored', () {
      final e = computeEffective(_server, _tool('t'), [
        _rule('Off', [_reason], enabled: false),
        _rule('Elsewhere', [_reason], serverIds: ['s2']),
      ], null);
      expect(e.isModified, isFalse);
      expect(e.rules, isEmpty);
    });

    test('instructions from rules and the per-tool override are appended', () {
      final e = computeEffective(_server, _tool('t'), [
        _rule('R', [], instructions: 'Prefer small files.'),
      ], const ToolOverride(instructions: 'Never use on /etc.'));
      expect(
        e.description,
        'Does a thing.\n\nPrefer small files.\nNever use on /etc.',
      );
    });

    test('hidden override makes the tool invisible', () {
      final e = computeEffective(
        _server,
        _tool('t'),
        const [],
        const ToolOverride(hidden: true),
      );
      expect(e.visible, isFalse);
    });
  });

  group('prepareCall', () {
    EffectiveTool eff(List<ToolRule> rules, {McpTool? tool}) =>
        computeEffective(
          _server,
          tool ??
              _tool(
                't',
                props: {
                  'q': {'type': 'string'},
                },
              ),
          rules,
          null,
        );

    test('missing required extras reject the call with a message the model can act on', () {
      final e = eff([
        _rule('R', [
          _reason,
          const RuleArg(name: 'expected_result', required: true),
        ]),
      ]);
      final r = prepareCall(e, {'q': 'x'});
      expect(
        r.error,
        'Missing required arguments: reason, expected_result. Provide them and call the tool again.',
      );
      expect(
        prepareCall(e, {
          'q': 'x',
          'reason': '   ',
          'expected_result': 'ok',
        }).error,
        contains('reason'),
        reason: 'blank counts as missing',
      );
    });

    test('audit-only arguments are stripped from the forwarded call but kept as context', () {
      final e = eff([
        _rule('R', [_reason]),
      ]);
      final r = prepareCall(e, {'q': 'x', 'reason': 'because'});
      expect(r.error, isNull);
      expect(r.forwarded, {'q': 'x'});
      expect(r.context, {'reason': 'because'});
    });

    test('forwarded arguments stay in the call and in the context', () {
      final e = eff([
        _rule('R', [const RuleArg(name: 'ticket', forward: true)]),
      ]);
      final r = prepareCall(e, {'q': 'x', 'ticket': 'ABC-1'});
      expect(r.forwarded, {'q': 'x', 'ticket': 'ABC-1'});
      expect(r.context, {'ticket': 'ABC-1'});
    });

    test('optional extras may be omitted', () {
      final e = eff([
        _rule('R', [const RuleArg(name: 'chat_id')]),
      ]);
      final r = prepareCall(e, {'q': 'x'});
      expect(r.error, isNull);
      expect(r.context, isEmpty);
    });

    test(
      'hard-coded values are injected and the model cannot override them',
      () {
        final e = eff([
          _rule('Pin', [
            const RuleArg(
              name: 'workspace',
              source: ArgSource.hardcoded,
              fixedValue: 'dev',
            ),
            const RuleArg(
              name: 'limit',
              source: ArgSource.hardcoded,
              type: 'integer',
              fixedValue: '5',
            ),
            const RuleArg(
              name: 'dry',
              source: ArgSource.hardcoded,
              type: 'boolean',
              fixedValue: 'true',
            ),
            const RuleArg(
              name: 'opts',
              source: ArgSource.hardcoded,
              fixedValue: '{"a":1}',
            ),
          ]),
        ]);
        final r = prepareCall(e, {
          'q': 'x',
          'workspace': 'prod',
          'limit': 9999,
        });
        expect(r.forwarded, {
          'q': 'x',
          'workspace': 'dev',
          'limit': 5,
          'dry': true,
          'opts': {'a': 1},
        });
      },
    );
  });

  group('presets', () {
    test('match the old project: reason, expected result, explanation, chat context', () {
      final byId = {for (final p in rulePresets) p.id: p};
      expect(byId['reason_expected']!.args.map((a) => a.name), [
        'reason',
        'expected_result',
      ]);
      expect(
        byId['reason_expected']!.args.every((a) => a.required && !a.forward),
        isTrue,
      );
      expect(byId['explanation']!.args.single.name, 'explanation');
      expect(byId['chat_context']!.args.every((a) => !a.required), isTrue);
    });
  });

  group('store', () {
    test('rules and overrides persist, reorder and bulk-apply', () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      final store = c.read(toolRulesProvider.notifier);

      final bulk = store.addToTools(
        name: 'Reason on 2 tools',
        toolKeys: ['s1/a', 's1/b'],
        args: [_reason],
      );
      store.upsert(_rule('Second', [const RuleArg(name: 'x')]));
      store.move(1, 0);
      expect(c.read(toolRulesProvider).rules.map((r) => r.name), [
        'Second',
        'Reason on 2 tools',
      ]);

      store.setHidden(['s1/a', 's1/b'], true);
      store.setHidden(['s1/b'], false);
      expect(c.read(toolRulesProvider).overrides.keys, [
        's1/a',
      ], reason: 'empty overrides are dropped');

      store.setEnabled(bulk.id, false);
      store.remove('Second');
      expect(c.read(toolRulesProvider).rules.single.enabled, isFalse);

      final stored = c.read(toolRulesProvider);
      final c2 = await makeContainer(
        prefs: {
          'mcpm.toolrules.v1': jsonEncode({
            'rules': [for (final r in stored.rules) r.toJson()],
            'overrides': {
              for (final e in stored.overrides.entries) e.key: e.value.toJson(),
            },
          }),
        },
      );
      addTearDown(c2.dispose);
      final restored = c2.read(toolRulesProvider);
      expect(restored.rules.single.toolKeys, ['s1/a', 's1/b']);
      expect(restored.rules.single.args.single.name, 'reason');
      expect(restored.overrides['s1/a']!.hidden, isTrue);
    });
  });

  group('in the Operator', () {
    final lookup = {
      'name': 'lookup',
      'description': 'Read something',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'q': {'type': 'string'},
        },
        'required': ['q'],
      },
      'annotations': {'readOnlyHint': true},
    };
    final secret = {
      'name': 'secret',
      'description': 'Internal',
      'inputSchema': {'type': 'object'},
      'annotations': {'readOnlyHint': true},
    };

    Future<(ProviderContainer, ScriptedLlm, FakeMcpServer)> setup(
      List<List<LlmEvent>> turns, {
      List<ToolRule> rules = const [],
      Map<String, ToolOverride> overrides = const {},
    }) async {
      final calls = <Map<String, dynamic>>[];
      final server = FakeMcpServer(
        tools: [lookup, secret],
        handlers: {
          'lookup': (args) {
            calls.add(args);
            return textResult('found ${args['q']}');
          },
          'secret': (_) => textResult('s'),
        },
      );
      final llm = ScriptedLlm(turns);
      final c = await makeContainer(server: server, llm: llm);
      addTearDown(c.dispose);
      final id =
          (await c
                  .read(mcpHubProvider.notifier)
                  .addServer(name: 'Docs', url: 'https://d.test/mcp'))
              .config
              .id;
      final store = c.read(toolRulesProvider.notifier);
      for (final r in rules) {
        store.upsert(
          r.copyWith(
            toolKeys: r.scope == RuleScope.tools ? ['$id/lookup'] : null,
          ),
        );
      }
      for (final e in overrides.entries) {
        store.setOverride('$id/${e.key}', e.value);
      }
      c.read(auditLogProvider.notifier).clear();
      server.bodies.clear();
      return (c, llm, server);
    }

    LlmToolCallsEvent call(String id, String name, Map<String, dynamic> args) =>
        LlmToolCallsEvent([LlmToolCall(id: id, name: name, arguments: args)]);

    test('the model sees the extra arguments; reason and expected result stay out of the forwarded call', () async {
      final (c, llm, server) = await setup(
        [
          [
            call('c1', 'Docs__lookup', {
              'q': 'gemma',
              'reason': 'user asked',
              'expected_result': 'a hit',
            }),
          ],
          [const LlmTextDelta('done'), const LlmDone()],
        ],
        rules: [
          _rule(
            'RE',
            rulePresets.firstWhere((p) => p.id == 'reason_expected').args,
          ),
        ],
      );

      await c.read(chatControllerProvider.notifier).send('look up gemma');

      final spec = llm.toolSpecs.first.firstWhere(
        (t) => t.name == 'Docs__lookup',
      );
      final props = spec.parameters['properties'] as Map;
      expect(props.keys, containsAll(['q', 'reason', 'expected_result']));
      expect(
        spec.parameters['required'],
        containsAll(['q', 'reason', 'expected_result']),
      );

      final upstream = server.bodies
          .where((b) => b['method'] == 'tools/call')
          .single['params']['arguments'];
      expect(upstream, {
        'q': 'gemma',
      }, reason: 'audit-only values never reach the server');

      final event = c
          .read(auditLogProvider)
          .firstWhere((e) => e.kind == AuditKind.toolCall);
      expect(event.status, AuditStatus.success);
      expect(event.args, contains('reason'), reason: 'what the model sent');
      expect(
        event.forwarded,
        isNot(contains('reason')),
        reason: 'what the server got',
      );
      expect(jsonDecode(event.context!), {
        'reason': 'user asked',
        'expected_result': 'a hit',
      });
    });

    test('a call without the required reason is bounced back to the model and audited', () async {
      final (c, llm, server) = await setup(
        [
          [
            call('c1', 'Docs__lookup', {'q': 'gemma'}),
          ],
          [const LlmTextDelta('sorry'), const LlmDone()],
        ],
        rules: [
          _rule('R', [_reason]),
        ],
      );

      await c.read(chatControllerProvider.notifier).send('look up gemma');

      expect(server.bodies.where((b) => b['method'] == 'tools/call'), isEmpty);
      expect(
        llm.received[1].last.content,
        contains('Missing required argument: reason'),
      );
      final tool = c
          .read(chatControllerProvider)
          .items
          .whereType<ToolItem>()
          .single;
      expect(tool.status, ToolStatus.error);
      final event = c.read(auditLogProvider).first;
      expect(event.status, AuditStatus.error);
      expect(event.error, contains('Rejected before forwarding'));
    });

    test(
      'hidden tools are not offered; hard-coded values are injected',
      () async {
        final (c, llm, server) = await setup(
          [
            [
              call('c1', 'Docs__lookup', {'q': 'x', 'scope': 'prod'}),
            ],
            [const LlmTextDelta('ok'), const LlmDone()],
          ],
          rules: [
            _rule('Pin', [
              const RuleArg(
                name: 'scope',
                source: ArgSource.hardcoded,
                fixedValue: 'dev',
              ),
            ]),
          ],
          overrides: {'secret': const ToolOverride(hidden: true)},
        );

        await c.read(chatControllerProvider.notifier).send('go');

        final names = llm.toolSpecs.first.map((t) => t.name);
        expect(names, contains('Docs__lookup'));
        expect(names, isNot(contains('Docs__secret')));
        final upstream = server.bodies
            .where((b) => b['method'] == 'tools/call')
            .single['params']['arguments'];
        expect(upstream, {'q': 'x', 'scope': 'dev'});
      },
    );

    test('rules apply to tools discovered later: scope "all" needs no re-selecting', () async {
      final (c, llm, _) = await setup(
        [
          [const LlmTextDelta('hi'), const LlmDone()],
        ],
        rules: [
          _rule('R', [_reason]),
        ],
      );
      await c.read(chatControllerProvider.notifier).send('hi');
      final specs = llm.toolSpecs.first.where(
        (t) => t.name.startsWith('Docs__'),
      );
      expect(specs, isNotEmpty);
      for (final t in specs) {
        expect(
          (t.parameters['properties'] as Map).containsKey('reason'),
          isTrue,
          reason: t.name,
        );
      }
    });

    test(
      '"confirm read-only tools" setting asks even for readOnly tools',
      () async {
        final (c, _, _) = await setup([
          [
            call('c1', 'Docs__lookup', {'q': 'x'}),
          ],
          [const LlmTextDelta('ok'), const LlmDone()],
        ]);
        c
            .read(appSettingsProvider.notifier)
            .update((s) => s.copyWith(confirmReadOnly: true));
        final controller = c.read(chatControllerProvider.notifier);

        final run = controller.send('go');
        await pumpEventQueue();
        expect(
          c
              .read(chatControllerProvider)
              .items
              .whereType<ToolItem>()
              .single
              .status,
          ToolStatus.awaitingApproval,
        );
        controller.decide('c1', ApprovalDecision.approveOnce);
        await run;
      },
    );
  });
}
