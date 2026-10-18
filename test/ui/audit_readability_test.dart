import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/redact.dart';
import 'package:mcp_manager/router/pages/audit/audit_page.dart' show actorLabel;

import '../support/app_harness.dart';

void _connect(
  AuditLog log, {
  String server = 'Docs',
  String id = 'srv1',
  AuditStatus status = AuditStatus.success,
}) => log.record(
  kind: AuditKind.serverConnect,
  status: status,
  source: AuditSource.system,
  actor: 'system',
  serverId: id,
  serverName: server,
  durationMs: 100,
  result: status == AuditStatus.success ? 'fake 1.0 · 3 tools' : null,
  error: status == AuditStatus.error ? 'connection refused' : null,
);

Future<ProviderContainer> _open(WidgetTester tester) async {
  final c = await pumpApp(tester);
  await goTo(tester, '/audit');
  return c;
}

AuditLog _log(ProviderContainer c) => c.read(auditLogProvider.notifier);

/// Text inside the open detail dialog (the list behind it repeats some of it).
Finder _inDialog(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

void main() {
  group('actorLabel', () {
    test('speaks in words', () {
      expect(actorLabel('user'), 'You');
      expect(actorLabel('system'), 'System');
      expect(
        actorLabel('operator:nvidia/nemotron-3-super-120b-a12b:free'),
        'Chat · nemotron-3-super-120b-a12b:free',
      );
      expect(actorLabel('operator:gemma4'), 'Chat · gemma4');
      expect(actorLabel('something-else'), 'something-else');
    });
  });

  group('audit log page', () {
    testWidgets('counts one event as "1 event"', (tester) async {
      final c = await _open(tester);
      _log(c).record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.workbench,
        actor: 'user',
        serverName: 'Docs',
        toolName: 'lookup',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1 event · newest first'), findsOneWidget);
      expect(find.textContaining('1 events'), findsNothing);
    });

    testWidgets('the second tab is called Activity', (tester) async {
      await _open(tester);
      expect(find.text('Activity (0)'), findsOneWidget);
      expect(find.textContaining('Dashboard'), findsNothing);
    });

    testWidgets('rows say who did it, how it was approved and what came back', (
      tester,
    ) async {
      final c = await _open(tester);
      _log(c)
        ..record(
          kind: AuditKind.toolCall,
          status: AuditStatus.success,
          source: AuditSource.operator,
          actor: 'operator:nvidia/nemotron-3-super-120b-a12b:free',
          serverName: 'Docs',
          toolName: 'get_file',
          durationMs: 76,
          approval: 'automatic',
          result: '{"path":"/app/main.dart","size":120}',
        )
        ..record(
          kind: AuditKind.toolCall,
          status: AuditStatus.error,
          source: AuditSource.workbench,
          actor: 'user',
          serverName: 'Docs',
          toolName: 'write_file',
          error: 'permission denied',
          approval: 'user',
        );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Chat · nemotron-3-super-120b-a12b:free'),
        findsOneWidget,
      );
      expect(find.textContaining('automatic mode'), findsOneWidget);
      expect(find.textContaining('You · approved by you'), findsOneWidget);
      expect(find.text('permission denied'), findsOneWidget);
      expect(
        find.textContaining('path: /app/main.dart · size: 120'),
        findsOneWidget,
        reason: 'JSON is described by its keys, not dumped',
      );
      expect(find.textContaining('{"path"'), findsNothing);
      expect(find.textContaining('operator:nvidia'), findsNothing);
    });

    testWidgets('repeated successful connections fold into one row', (
      tester,
    ) async {
      final c = await _open(tester);
      final log = _log(c);
      for (var i = 0; i < 5; i++) {
        _connect(log);
      }
      await tester.tap(find.textContaining('Activity ('));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connect Docs  ×5'), findsOneWidget);
      expect(find.text('connection refused'), findsNothing);

      await tester.tap(find.textContaining('Connect Docs  ×5'));
      await tester.pumpAndSettle();
      expect(find.textContaining('fake 1.0 · 3 tools'), findsNWidgets(5));
    });

    testWidgets('a failure, or another server, breaks the run', (tester) async {
      final c = await _open(tester);
      final log = _log(c);
      // Oldest first, since the newest ends up on top.
      _connect(log);
      _connect(log);
      _connect(log, status: AuditStatus.error);
      _connect(log, server: 'Other', id: 'srv2');
      _connect(log);
      _connect(log);
      await tester.tap(find.textContaining('Activity ('));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connect Docs  ×2'), findsNWidgets(2));
      expect(find.text('Connect Other'), findsOneWidget);
      expect(find.text('connection refused'), findsOneWidget);
    });

    testWidgets('tool calls are never folded', (tester) async {
      final c = await _open(tester);
      for (var i = 0; i < 4; i++) {
        _log(c).record(
          kind: AuditKind.toolCall,
          status: AuditStatus.success,
          source: AuditSource.workbench,
          actor: 'user',
          serverId: 'srv1',
          serverName: 'Docs',
          toolName: 'lookup',
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('Docs · lookup'), findsNWidgets(4));
      expect(find.textContaining('×'), findsNothing);
    });

    testWidgets('a long JSON result opens as readable text, with a note', (
      tester,
    ) async {
      final c = await _open(tester);
      final big = '{"path":"/app/main.dart","content":"${'line\\n' * 2000}"}';
      _log(c).record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.operator,
        actor: 'operator:gemma4',
        serverName: 'Docs',
        toolName: 'get_file',
        result: redactedPreview(big),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs · get_file'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('audit-shortened-note')),
        findsOneWidget,
      );
      // Real lines, not one string full of backslash-n.
      expect(
        _inDialog(find.textContaining('path: /app/main.dart')),
        findsOneWidget,
      );
      expect(_inDialog(find.textContaining(r'\n')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('audit-raw-Result')));
      await tester.pumpAndSettle();
      expect(
        _inDialog(find.textContaining('"path": "/app/main.dart"')),
        findsOneWidget,
      );
      expect(find.text('Show readable'), findsOneWidget);
    });

    testWidgets('a result stored by an older version is repaired for display', (
      tester,
    ) async {
      final c = await _open(tester);
      // Cut in the middle of the file text, as before this fix.
      const legacy =
          r'{"path":"/home/luis/app/mcp_sse_client.dart","content":"import \"dart:async\";\n'
          r'class McpSseClient implements McpConnection {\n  final int x;\n'
          '… [truncated 11345 chars]';
      _log(c).record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.operator,
        actor: 'operator:nvidia/nemotron-3-super-120b-a12b:free',
        serverName: 'VSCode',
        toolName: 'get_active_file',
        result: legacy,
      );
      await tester.pumpAndSettle();

      // The row says what the result is instead of showing its first bytes.
      expect(
        find.textContaining(
          'path: /home/luis/app/mcp_sse_client.dart · content: 11.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('{"path"'), findsNothing);

      await tester.tap(find.text('VSCode · get_active_file'));
      await tester.pumpAndSettle();
      expect(
        _inDialog(
          find.textContaining('class McpSseClient implements McpConnection {'),
        ),
        findsOneWidget,
      );
      expect(_inDialog(find.textContaining(r'\n')), findsNothing);
      expect(
        find.byKey(const ValueKey('audit-shortened-note')),
        findsOneWidget,
      );
    });

    testWidgets('sources are named for people, not for the code', (
      tester,
    ) async {
      final c = await _open(tester);
      _log(c).record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.operator,
        actor: 'operator:gemma4',
        serverName: 'Docs',
        toolName: 'lookup',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs · lookup'));
      await tester.pumpAndSettle();
      expect(
        _inDialog(find.text('Chat')),
        findsOneWidget,
        reason: 'the source chip',
      );
      expect(find.text('operator'), findsNothing);
    });

    testWidgets('a short result has no "shortened" note', (tester) async {
      final c = await _open(tester);
      _log(c).record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.workbench,
        actor: 'user',
        serverName: 'Docs',
        toolName: 'lookup',
        result: redactedPreview('{"ok":true}'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs · lookup'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audit-shortened-note')), findsNothing);
    });

    testWidgets('says when the log is full and old events are dropped', (
      tester,
    ) async {
      final c = await _open(tester);
      expect(find.textContaining('The log keeps the latest'), findsNothing);
      for (var i = 0; i < auditCapacity; i++) {
        _connect(_log(c), id: 'srv$i', server: 'S$i');
      }
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The log keeps the latest $auditCapacity events'),
        findsOneWidget,
      );
    });
  });
}
