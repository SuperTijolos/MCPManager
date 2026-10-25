import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/ui/download.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

AuditEvent _event(
  String id,
  DateTime at, {
  AuditKind kind = AuditKind.toolCall,
  AuditStatus status = AuditStatus.success,
  String? server = 'Docs',
  String? serverId = 'srv1',
  String? tool = 'lookup',
  String? args,
  String? result,
  String? conversationId,
}) => AuditEvent(
  id: id,
  timestamp: at,
  kind: kind,
  status: status,
  source: AuditSource.workbench,
  actor: 'user',
  serverId: serverId,
  serverName: server,
  toolName: tool,
  args: args,
  result: result,
  conversationId: conversationId,
);

Future<ProviderContainer> _open(
  WidgetTester tester,
  List<AuditEvent> events, {
  List<Override> overrides = const [],
  FakeMcpServer? server,
  ScriptedLlm? llm,
}) async {
  final c = await pumpApp(
    tester,
    server: server,
    llm: llm,
    overrides: overrides,
    audit: events,
  );
  await goTo(tester, '/audit');
  return c;
}

DateTime get _now => DateTime.now();

void main() {
  group('day headings', () {
    testWidgets('group rows under Today, Yesterday and an older date', (
      tester,
    ) async {
      final threeDaysAgo = _now.subtract(const Duration(days: 3));
      await _open(tester, [
        _event('a', _now.subtract(const Duration(minutes: 1)), tool: 'new_one'),
        _event('b', _now.subtract(const Duration(days: 1)), tool: 'mid_one'),
        _event('c', threeDaysAgo, tool: 'old_one'),
      ]);

      expect(find.byKey(const ValueKey('audit-day-Today')), findsOneWidget);
      expect(find.byKey(const ValueKey('audit-day-Yesterday')), findsOneWidget);
      final y = threeDaysAgo.year.toString();
      expect(find.textContaining(y), findsWidgets);
      // Under a heading a row only needs the time of day.
      expect(
        find.textContaining(RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
        findsNothing,
      );
    });

    testWidgets('a heading appears once per day, not per row', (tester) async {
      await _open(tester, [
        for (var i = 0; i < 4; i++)
          _event('e$i', _now.subtract(Duration(seconds: i)), tool: 't$i'),
      ]);
      expect(find.byKey(const ValueKey('audit-day-Today')), findsOneWidget);
    });
  });

  group('filters', () {
    final events = [
      _event(
        '1',
        _now.subtract(const Duration(minutes: 5)),
        tool: 'recent_tool',
      ),
      _event(
        '2',
        _now.subtract(const Duration(hours: 5)),
        tool: 'morning_tool',
      ),
      _event('3', _now.subtract(const Duration(days: 3)), tool: 'old_tool'),
      _event(
        '4',
        _now.subtract(const Duration(minutes: 9)),
        tool: 'other_tool',
        server: 'Files',
        serverId: 'srv2',
      ),
    ];

    Future<void> pick(WidgetTester tester, String key, String label) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('a time range keeps only recent events', (tester) async {
      await _open(tester, events);
      expect(find.text('Docs · old_tool'), findsOneWidget);

      await pick(tester, 'audit-range', 'Last 24 hours');
      expect(find.text('Docs · old_tool'), findsNothing);
      expect(find.text('Docs · morning_tool'), findsOneWidget);

      await pick(tester, 'audit-range', 'Last hour');
      expect(find.text('Docs · morning_tool'), findsNothing);
      expect(find.text('Docs · recent_tool'), findsOneWidget);
      expect(find.textContaining('of 4 events match'), findsOneWidget);
    });

    testWidgets('server and tool filters narrow each other', (tester) async {
      await _open(tester, events);

      await pick(tester, 'audit-server', 'Files');
      expect(find.text('Files · other_tool'), findsOneWidget);
      expect(find.text('Docs · recent_tool'), findsNothing);

      await pick(tester, 'audit-server', 'All servers');
      await pick(tester, 'audit-tool', 'old_tool');
      expect(find.text('Docs · old_tool'), findsOneWidget);
      expect(find.text('Docs · recent_tool'), findsNothing);
    });

    testWidgets('the tool list follows the chosen server', (tester) async {
      await _open(tester, events);
      await pick(tester, 'audit-server', 'Files');
      // Files has a single tool, so there is nothing to choose between.
      expect(find.byKey(const ValueKey('audit-tool')), findsNothing);
    });

    testWidgets('Reset filters clears the new filters too', (tester) async {
      await _open(tester, events);
      await pick(tester, 'audit-range', 'Last hour');
      await pick(tester, 'audit-server', 'Files');
      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();
      expect(find.text('Docs · old_tool'), findsOneWidget);
      expect(find.text('Files · other_tool'), findsOneWidget);
    });
  });

  group('export', () {
    final events = [
      _event('1', _now, tool: 'lookup', result: '{"ok":true}'),
      _event('2', _now.subtract(const Duration(minutes: 1)), tool: 'other'),
    ];

    testWidgets('downloads a CSV file of what is shown', (tester) async {
      final saved = <({String name, String content, String mime})>[];
      await _open(
        tester,
        events,
        overrides: [
          fileDownloadProvider.overrideWithValue((
            name,
            content, {
            String mime = 'text/plain',
          }) {
            saved.add((name: name, content: content, mime: mime));
            return true;
          }),
        ],
      );

      await tester.tap(find.byKey(const ValueKey('audit-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CSV'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('export-download')));
      await tester.pumpAndSettle();

      final file = saved.single;
      expect(
        file.name,
        matches(RegExp(r'^mcp-manager-audit-\d{8}-\d{6}\.csv$')),
      );
      expect(file.mime, 'text/csv');
      expect(file.content, startsWith('time,kind,status'));
      expect(file.content, contains('lookup'));
      expect(file.content, contains('other'));
      expect(find.textContaining('Saved 2 events'), findsOneWidget);
    });

    testWidgets('JSON is the default and respects the filters', (tester) async {
      final saved = <String>[];
      await _open(
        tester,
        events,
        overrides: [
          fileDownloadProvider.overrideWithValue((
            name,
            content, {
            String mime = 'text/plain',
          }) {
            saved
              ..add(name)
              ..add(content);
            return true;
          }),
        ],
      );
      await tester.enterText(find.byType(TextField).first, 'other');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audit-export')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('the ones matching your filters'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('export-download')));
      await tester.pumpAndSettle();

      expect(saved.first, endsWith('.json'));
      final exported = jsonDecode(saved.last) as List;
      expect(exported, hasLength(1));
      expect((exported.single as Map)['tool'], 'other');
    });

    testWidgets('where downloads are impossible it copies instead', (
      tester,
    ) async {
      await _open(
        tester,
        events,
        overrides: [
          fileDownloadProvider.overrideWithValue(
            (name, content, {String mime = 'text/plain'}) => false,
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('audit-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('export-download')));
      await tester.pumpAndSettle();
      expect(find.textContaining('copied 2 events instead'), findsOneWidget);
    });
  });

  group('clearing', () {
    final events = [
      _event('1', _now, tool: 'recent'),
      _event('2', _now.subtract(const Duration(days: 10)), tool: 'ten_days'),
      _event('3', _now.subtract(const Duration(days: 40)), tool: 'forty_days'),
      _event(
        '4',
        _now,
        kind: AuditKind.serverConnect,
        tool: null,
        result: 'fake 1.0',
      ),
    ];

    Future<void> openClear(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('audit-clear')));
      await tester.pumpAndSettle();
    }

    testWidgets('shows how many events each choice removes', (tester) async {
      await _open(tester, events);
      await openClear(tester);
      expect(find.text('Everything (4)'), findsOneWidget);
      expect(find.text('Tool calls only (3)'), findsOneWidget);
      expect(find.text('Activity only (1)'), findsOneWidget);
      expect(find.text('Older than 7 days (2)'), findsOneWidget);
      expect(find.text('Older than 30 days (1)'), findsOneWidget);
    });

    testWidgets('removes only what was chosen', (tester) async {
      final c = await _open(tester, events);
      await openClear(tester);
      await tester.tap(find.byKey(const ValueKey('clear-older30')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clear-confirm')));
      await tester.pumpAndSettle();

      expect(
        c.read(auditLogProvider).map((e) => e.id),
        unorderedEquals(['1', '2', '4']),
      );
      expect(find.textContaining('Cleared 1 event'), findsOneWidget);
    });

    testWidgets('can clear activity or tool calls on their own', (
      tester,
    ) async {
      final c = await _open(tester, events);
      await openClear(tester);
      await tester.tap(find.byKey(const ValueKey('clear-activity')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clear-confirm')));
      await tester.pumpAndSettle();
      expect(
        c.read(auditLogProvider).map((e) => e.id),
        unorderedEquals(['1', '2', '3']),
      );

      await openClear(tester);
      await tester.tap(find.byKey(const ValueKey('clear-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clear-confirm')));
      await tester.pumpAndSettle();
      expect(c.read(auditLogProvider), isEmpty);
    });

    testWidgets('"Everything" empties the log', (tester) async {
      final c = await _open(tester, events);
      await openClear(tester);
      await tester.tap(find.byKey(const ValueKey('clear-everything')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clear-confirm')));
      await tester.pumpAndSettle();
      expect(c.read(auditLogProvider), isEmpty);
      expect(find.text('No tool calls yet'), findsOneWidget);
    });

    testWidgets('cannot confirm a choice that removes nothing', (tester) async {
      await _open(tester, [_event('1', _now)]);
      await openClear(tester);
      // "Older than 7 days" is the default and matches nothing here.
      final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('clear-confirm')),
      );
      expect(confirm.onPressed, isNull);
    });

    testWidgets('Cancel keeps everything', (tester) async {
      final c = await _open(tester, events);
      await openClear(tester);
      await tester.tap(find.byKey(const ValueKey('clear-everything')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.read(auditLogProvider), hasLength(4));
    });
  });

  group('links from an event', () {
    final tools = [
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
    ];

    Future<(ProviderContainer, String)> openWithServer(
      WidgetTester tester, {
      String? args,
      String? conversationId,
      ScriptedLlm? llm,
    }) async {
      final server = FakeMcpServer(tools: tools);
      final c = await pumpApp(tester, server: server, llm: llm);
      final runtime = await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Docs', url: 'https://docs.test/mcp');
      final id = runtime.config.id;
      c
          .read(auditLogProvider.notifier)
          .record(
            kind: AuditKind.toolCall,
            status: AuditStatus.success,
            source: AuditSource.workbench,
            actor: 'user',
            serverId: id,
            serverName: 'Docs',
            toolName: 'lookup',
            args: args,
            conversationId: conversationId,
          );
      await goTo(tester, '/audit');
      await tester.tap(find.text('Docs · lookup'));
      await tester.pumpAndSettle();
      return (c, id);
    }

    String path(WidgetTester tester) =>
        GoRouter.of(tester.element(find.byType(Scaffold).first))
            .routeInformationProvider
            .value
            .uri
            .path;

    testWidgets('Open tool shows that tool on the Tools page', (tester) async {
      await openWithServer(tester);
      await tester.tap(find.byKey(const ValueKey('audit-open-tool')));
      await tester.pumpAndSettle();

      expect(path(tester), '/mcp-tools');
      expect(
        find.widgetWithText(Tab, 'Schema'),
        findsOneWidget,
        reason: 'the tool detail is open',
      );
      expect(find.text('Explore your MCP tools'), findsNothing);
    });

    testWidgets('Test again starts the Test tab with the recorded arguments', (
      tester,
    ) async {
      await openWithServer(tester, args: '{"q":"report"}');
      await tester.tap(find.byKey(const ValueKey('audit-test-again')));
      await tester.pumpAndSettle();

      expect(path(tester), '/mcp-tools');
      expect(find.textContaining('"q": "report"'), findsOneWidget);
    });

    testWidgets('Test again is not offered for masked or shortened arguments', (
      tester,
    ) async {
      await openWithServer(tester, args: '{"q":"x","token":"[redacted]"}');
      expect(find.byKey(const ValueKey('audit-open-tool')), findsOneWidget);
      expect(find.byKey(const ValueKey('audit-test-again')), findsNothing);
    });

    testWidgets('no tool links once the tool is gone', (tester) async {
      final server = FakeMcpServer(tools: tools);
      final c = await pumpApp(tester, server: server);
      c
          .read(auditLogProvider.notifier)
          .record(
            kind: AuditKind.toolCall,
            status: AuditStatus.success,
            source: AuditSource.workbench,
            actor: 'user',
            serverId: 'removed-server',
            serverName: 'Gone',
            toolName: 'lookup',
          );
      await goTo(tester, '/audit');
      await tester.tap(find.text('Gone · lookup'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audit-open-tool')), findsNothing);
      expect(find.byKey(const ValueKey('audit-test-again')), findsNothing);
    });

    testWidgets('Open chat returns to the conversation that made the call', (
      tester,
    ) async {
      final llm = ScriptedLlm([
        [const LlmTextDelta('hello'), const LlmDone()],
        [const LlmTextDelta('other'), const LlmDone()],
      ]);
      final server = FakeMcpServer(tools: tools);
      final c = await pumpApp(tester, server: server, llm: llm);
      final chat = c.read(chatControllerProvider.notifier);
      await chat.send('first conversation');
      final conversation = c.read(chatControllerProvider).activeId!;
      chat.newConversation();
      await chat.send('second conversation');
      expect(c.read(chatControllerProvider).activeId, isNot(conversation));

      c
          .read(auditLogProvider.notifier)
          .record(
            kind: AuditKind.toolCall,
            status: AuditStatus.success,
            source: AuditSource.operator,
            actor: 'operator:gemma4',
            serverName: 'Docs',
            toolName: 'lookup',
            conversationId: conversation,
          );
      await goTo(tester, '/audit');
      await tester.tap(find.text('Docs · lookup'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audit-open-chat')));
      await tester.pumpAndSettle();

      expect(path(tester), '/chat');
      expect(c.read(chatControllerProvider).activeId, conversation);
      expect(find.text('first conversation'), findsWidgets);
    });

    testWidgets('no chat link when the conversation was deleted', (
      tester,
    ) async {
      await openWithServer(tester, conversationId: 'chat_deleted');
      expect(find.byKey(const ValueKey('audit-open-chat')), findsNothing);
    });
  });
}
