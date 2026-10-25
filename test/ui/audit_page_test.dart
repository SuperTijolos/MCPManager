import 'package:flutter/material.dart';
import 'package:mcp_manager/ui/widgets.dart' show CodeBlock;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/ui/pagination.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

void main() {
  group('PageRange', () {
    test('slices and labels', () {
      final items = List.generate(137, (i) => i);
      final first = PageRange(total: 137, page: 0, pageSize: 25);
      expect(first.pageCount, 6);
      expect(first.label, '1–25 of 137');
      expect(first.slice(items).first, 0);
      expect(first.hasPrevious, isFalse);
      expect(first.hasNext, isTrue);

      final last = PageRange(total: 137, page: 5, pageSize: 25);
      expect(last.label, '126–137 of 137');
      expect(last.slice(items), hasLength(12));
      expect(last.hasNext, isFalse);
    });

    test(
      'out-of-range pages are clamped (e.g. after filtering shrinks the list)',
      () {
        final r = PageRange(total: 30, page: 9, pageSize: 25);
        expect(r.page, 1);
        expect(r.label, '26–30 of 30');
        expect(PageRange(total: 30, page: -3, pageSize: 25).page, 0);
      },
    );

    test('an empty list is one empty page', () {
      final r = PageRange(total: 0, page: 4, pageSize: 25);
      expect(r.page, 0);
      expect(r.pageCount, 1);
      expect(r.label, '0 of 0');
      expect(r.slice(<int>[]), isEmpty);
    });

    test('exact multiples have no extra page', () {
      expect(PageRange(total: 50, page: 0, pageSize: 25).pageCount, 2);
      expect(PageRange(total: 51, page: 0, pageSize: 25).pageCount, 3);
    });
  });

  group('audit page', () {
    void seed(dynamic container, int n) {
      final log = container.read(auditLogProvider.notifier) as AuditLog;
      for (var i = 1; i <= n; i++) {
        log.record(
          kind: AuditKind.toolCall,
          status: i % 10 == 0 ? AuditStatus.error : AuditStatus.success,
          source: i % 2 == 0 ? AuditSource.operator : AuditSource.workbench,
          actor: 'user',
          serverName: 'Srv',
          toolName: 'tool_$i',
        );
      }
    }

    testWidgets('shows 25 per page, newest first, and pages through the rest', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      seed(c, 60);
      await goTo(tester, '/audit');

      expect(find.text('1–25 of 60'), findsOneWidget);
      expect(
        find.textContaining('tool_60'),
        findsOneWidget,
        reason: 'newest on top',
      );
      expect(find.textContaining('tool_36'), findsNothing);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('26–50 of 60'), findsOneWidget);
      expect(find.textContaining('tool_35'), findsOneWidget);
      expect(find.textContaining('tool_60'), findsNothing);

      await tester.tap(find.byTooltip('Last page'));
      await tester.pumpAndSettle();
      expect(find.text('51–60 of 60'), findsOneWidget);
      expect(find.textContaining('tool_10'), findsOneWidget);
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right),
      );
      expect(next.onPressed, isNull, reason: 'no page after the last');

      await tester.tap(find.byTooltip('First page'));
      await tester.pumpAndSettle();
      expect(find.text('1–25 of 60'), findsOneWidget);
    });

    testWidgets('changing the page size resets to the first page', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      seed(c, 60);
      await goTo(tester, '/audit');
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('25').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('10').last);
      await tester.pumpAndSettle();
      expect(find.text('1–10 of 60'), findsOneWidget);
      expect(find.text('1 / 6'), findsOneWidget);
    });

    testWidgets('filtering goes back to page one and updates the totals', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      seed(c, 60);
      await goTo(tester, '/audit');
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilterChip, 'error'));
      await tester.pumpAndSettle();
      expect(
        find.text('1–6 of 6'),
        findsOneWidget,
        reason: 'every 10th event failed',
      );
      expect(find.textContaining('6 of 60 events match'), findsOneWidget);

      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();
      expect(find.text('1–25 of 60'), findsOneWidget);
    });

    testWidgets(
      'an empty log has no pagination bar, a filtered-out one explains itself',
      (tester) async {
        final c = await pumpApp(tester);
        await goTo(tester, '/audit');
        expect(find.text('No tool calls yet'), findsOneWidget);
        expect(find.byTooltip('Next page'), findsNothing);

        seed(c, 3);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'nothing-matches');
        await tester.pumpAndSettle();
        expect(find.text('No events match the filters'), findsOneWidget);
      },
    );

    testWidgets('the audit-only values are labelled lines, not one sentence', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      await seedAudit(gatewayOf(c), [
        AuditEvent(
          id: 'why',
          timestamp: DateTime.now(),
          kind: AuditKind.toolCall,
          status: AuditStatus.success,
          source: AuditSource.portal,
          actor: 'ChatGPT',
          serverName: 'Docs',
          toolName: 'lookup',
          args: '{"q":"x","reason":"user asked","expected_result":"a page"}',
          forwarded: '{"q":"x"}',
          context: '{"reason":"user asked","expected_result":"a page"}',
          result: 'found x',
        ),
      ]);
      await c.read(auditLogProvider.notifier).reload();
      await goTo(tester, '/audit');

      expect(find.text('Reason'), findsOneWidget);
      expect(find.text('user asked'), findsOneWidget);
      expect(find.text('Expected result'), findsOneWidget);
      expect(find.text('a page'), findsOneWidget);
      expect(find.textContaining('reason: user asked'), findsNothing);
    });

    testWidgets(
      'the detail shows the why apart from the arguments, with coloured JSON',
      (tester) async {
        final c = await pumpApp(tester);
        await seedAudit(gatewayOf(c), [
          AuditEvent(
            id: 'reshaped',
            timestamp: DateTime.now(),
            kind: AuditKind.toolCall,
            status: AuditStatus.success,
            source: AuditSource.operator,
            actor: 'operator:gemma4',
            serverName: 'Docs',
            toolName: 'lookup',
            args: '{"q":"x","reason":"user asked"}',
            forwarded: '{"q":"x"}',
            context: '{"reason":"user asked"}',
            result: 'found x',
          ),
        ]);
        await c.read(auditLogProvider.notifier).reload();
        await goTo(tester, '/audit');

        await tester.tap(find.text('Docs · lookup'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget, reason: 'opens the detail');
        expect(find.text('Why'), findsOneWidget);
        expect(find.text('Arguments'), findsOneWidget);
        expect(
          find.text('Forwarded to the server'),
          findsNothing,
          reason: 'the same as the arguments once the why is set aside',
        );
        expect(find.text('reshaped by rules'), findsOneWidget);
        expect(find.text('Result'), findsWidgets);
        expect(
          find.byWidgetPredicate((w) => w is CodeBlock && w.json),
          findsWidgets,
          reason: 'the arguments are coloured JSON',
        );

        // The complete JSON, nothing left out, is one tab away.
        await tester.tap(find.byKey(const ValueKey('audit-tab-raw')));
        await tester.pumpAndSettle();
        expect(find.text('Arguments from the model'), findsOneWidget);
        expect(find.text('Forwarded to the server'), findsOneWidget);
        expect(find.text('Audit-only context'), findsOneWidget);
        expect(find.text('The whole event'), findsOneWidget);
        expect(
          find.textContaining('"reason": "user asked"'),
          findsWidgets,
          reason: 'the model\'s own arguments are whole here',
        );
      },
    );

    testWidgets('values a rule injected are shown as what was forwarded', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      await seedAudit(gatewayOf(c), [
        AuditEvent(
          id: 'injected',
          timestamp: DateTime.now(),
          kind: AuditKind.toolCall,
          status: AuditStatus.success,
          source: AuditSource.portal,
          actor: 'ChatGPT',
          serverName: 'Docs',
          toolName: 'lookup',
          args: '{"q":"x"}',
          forwarded: '{"q":"x","tenant":"acme"}',
          result: 'found x',
        ),
      ]);
      await c.read(auditLogProvider.notifier).reload();
      await goTo(tester, '/audit');
      await tester.tap(find.text('Docs · lookup'));
      await tester.pumpAndSettle();
      expect(find.text('Arguments from the model'), findsOneWidget);
      expect(find.text('Forwarded to the server'), findsOneWidget);
      expect(find.text('Why'), findsNothing);
    });

    testWidgets('filters by server and by portal', (tester) async {
      final c = await pumpApp(tester);
      AuditEvent call(String id, String server, String portal) => AuditEvent(
        id: id,
        timestamp: DateTime.now(),
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.portal,
        actor: 'ChatGPT',
        serverId: 'srv-$server',
        serverName: server,
        toolName: 'lookup',
        portalSlug: portal,
        result: 'ok',
      );
      await seedAudit(gatewayOf(c), [
        call('1', 'Docs', 'work'),
        call('2', 'Code', 'home'),
        call('3', 'Code', 'work'),
      ]);
      await c.read(auditLogProvider.notifier).reload();
      await goTo(tester, '/audit');
      expect(find.text('Docs · lookup'), findsOneWidget);
      expect(find.text('Code · lookup'), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('audit-portal')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('home').last);
      await tester.pumpAndSettle();
      expect(find.text('Code · lookup'), findsOneWidget);
      expect(find.text('Docs · lookup'), findsNothing);

      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audit-server')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs').last);
      await tester.pumpAndSettle();
      expect(find.text('Docs · lookup'), findsOneWidget);
      expect(find.text('Code · lookup'), findsNothing);
    });

    testWidgets('MCP tool calls and activity are separate views', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final log = c.read(auditLogProvider.notifier);
      seed(c, 4);
      log.record(
        kind: AuditKind.serverConnect,
        status: AuditStatus.success,
        source: AuditSource.system,
        actor: 'user',
        serverName: 'Docs',
      );
      log.record(
        kind: AuditKind.manage,
        status: AuditStatus.success,
        source: AuditSource.operator,
        actor: 'operator:gemma4',
        toolName: 'add_server',
      );
      await goTo(tester, '/audit');

      expect(find.text('MCP tools (4)'), findsOneWidget);
      expect(find.text('Activity (2)'), findsOneWidget);
      expect(find.text('1–4 of 4'), findsOneWidget, reason: 'tools by default');
      expect(find.textContaining('Connect Docs'), findsNothing);

      await tester.tap(find.text('Activity (2)'));
      await tester.pumpAndSettle();
      expect(find.text('1–2 of 2'), findsOneWidget);
      expect(find.textContaining('tool_1'), findsNothing);
      expect(find.text('Connect Docs'), findsOneWidget);
      expect(find.text('Manage · add_server'), findsOneWidget);
    });

    testWidgets('an empty activity view explains what belongs there', (
      tester,
    ) async {
      await pumpApp(tester);
      await goTo(tester, '/audit');
      await tester.tap(find.text('Activity (0)'));
      await tester.pumpAndSettle();
      expect(find.text('No activity yet'), findsOneWidget);
    });

    test('the log keeps up to a thousand events', () {
      expect(auditCapacity, 1000);
    });
  });
}
