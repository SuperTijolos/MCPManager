import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/audit/audit_export.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/fakes.dart';

AuditEvent _e(
  String id, {
  String? result,
  String? args,
  String? error,
  AuditKind kind = AuditKind.toolCall,
  DateTime? at,
}) => AuditEvent(
  id: id,
  timestamp: at ?? DateTime.utc(2026, 10, 18, 12, 30, 5),
  kind: kind,
  status: AuditStatus.success,
  source: AuditSource.workbench,
  actor: 'user',
  serverName: 'Docs',
  toolName: 'lookup',
  durationMs: 12,
  args: args,
  result: result,
  error: error,
  conversationId: 'chat_1',
);

void main() {
  group('auditToCsv', () {
    test('starts with a header and ends each row with CRLF', () {
      final csv = auditToCsv([_e('a')]);
      final lines = csv.split('\r\n');
      expect(
        lines.first,
        startsWith('time,kind,status,source,actor,server,tool'),
      );
      expect(lines[1], startsWith('2026-10-18T12:30:05.000Z,toolCall,success'));
      expect(lines.last, isEmpty, reason: 'a final line break');
      expect(lines[1], endsWith(',a,chat_1'));
    });

    test('quotes commas, quotes and line breaks', () {
      final csv = auditToCsv([
        _e('a', result: 'one, two', args: 'say "hi"', error: 'line1\nline2'),
      ]);
      expect(csv, contains('"one, two"'));
      expect(csv, contains('"say ""hi"""'));
      expect(csv, contains('"line1\nline2"'));
    });

    test('defuses cells a spreadsheet would run as formulas', () {
      final csv = auditToCsv([
        _e('a', result: '=HYPERLINK("http://evil")'),
        _e('b', result: '+1+1'),
        _e('c', result: '@SUM(A1)'),
        _e('d', result: '-2+3'),
      ]);
      expect(csv, isNot(contains(',=HYPERLINK')));
      expect(csv, contains("\"'=HYPERLINK"));
      expect(csv, contains(",'+1+1,"));
      expect(csv, contains(",'@SUM(A1),"));
      expect(csv, contains(",'-2+3,"));
    });

    test('no events is just the header', () {
      expect(auditToCsv(const []).trim().split('\r\n'), hasLength(1));
    });
  });

  group('AuditLog', () {
    test(
      'removeWhere deletes matches, persists, and reports the count',
      () async {
        final c = await makeContainer();
        addTearDown(c.dispose);
        final log = c.read(auditLogProvider.notifier);
        for (var i = 0; i < 5; i++) {
          log.record(
            kind: i.isEven ? AuditKind.toolCall : AuditKind.serverConnect,
            status: AuditStatus.success,
            source: AuditSource.system,
            actor: 'system',
            toolName: 't$i',
          );
        }

        final removed = log.removeWhere((e) => e.kind == AuditKind.toolCall);

        expect(removed, 3);
        expect(c.read(auditLogProvider), hasLength(2));
        expect(log.removeWhere((e) => false), 0);
        final stored = c
            .read(sharedPreferencesProvider)
            .getString('mcpm.audit.v1')!;
        expect(jsonDecode(stored) as List, hasLength(2));
      },
    );

    test('an event keeps its conversation id through JSON', () {
      final again = AuditEvent.fromJson(_e('a').toJson());
      expect(again.conversationId, 'chat_1');
      final none = AuditEvent.fromJson(
        AuditEvent(
          id: 'x',
          timestamp: DateTime.utc(2026),
          kind: AuditKind.manage,
          status: AuditStatus.success,
          source: AuditSource.system,
          actor: 'system',
        ).toJson(),
      );
      expect(none.conversationId, isNull);
    });
  });

  test(
    'tool calls made in a chat are stamped with that conversation',
    () async {
      final llm = ScriptedLlm([
        [
          LlmToolCallsEvent([
            const LlmToolCall(
              id: 'c1',
              name: 'Demo__lookup',
              arguments: {'q': 'x'},
            ),
          ]),
        ],
        [const LlmTextDelta('done'), const LlmDone()],
      ]);
      final server = FakeMcpServer(
        tools: [
          {
            'name': 'lookup',
            'description': 'Read',
            'inputSchema': {
              'type': 'object',
              'properties': {
                'q': {'type': 'string'},
              },
            },
            'annotations': {'readOnlyHint': true},
          },
        ],
        handlers: {'lookup': (a) => textResult('found ${a['q']}')},
      );
      final ProviderContainer c = await makeContainer(server: server, llm: llm);
      addTearDown(c.dispose);
      await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Demo', url: 'https://mcp.test/mcp');
      c.read(auditLogProvider.notifier).clear();

      await c.read(chatControllerProvider.notifier).send('look it up');

      final conversation = c.read(chatControllerProvider).activeId;
      expect(conversation, isNotNull);
      final call = c
          .read(auditLogProvider)
          .singleWhere((e) => e.kind == AuditKind.toolCall);
      expect(call.source, AuditSource.operator);
      expect(call.conversationId, conversation);
    },
  );

  test('calls from the Tools page carry no conversation', () async {
    final server = FakeMcpServer(
      tools: [
        {
          'name': 'lookup',
          'description': 'Read',
          'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      ],
      handlers: {'lookup': (_) => textResult('ok')},
    );
    final c = await makeContainer(server: server);
    addTearDown(c.dispose);
    final hub = c.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Demo',
      url: 'https://mcp.test/mcp',
    );
    c.read(auditLogProvider.notifier).clear();

    await hub.callTool(
      serverId: runtime.config.id,
      toolName: 'lookup',
      args: const {},
      source: AuditSource.workbench,
      actor: 'user',
    );

    expect(c.read(auditLogProvider).single.conversationId, isNull);
  });
}
