import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/ui/widgets.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  group('formatAgo', () {
    final now = DateTime(2026, 3, 10, 12);
    test('reads naturally for recent times', () {
      expect(
        formatAgo(now.subtract(const Duration(seconds: 20)), now: now),
        'just now',
      );
      expect(
        formatAgo(now.subtract(const Duration(minutes: 5)), now: now),
        '5 min ago',
      );
      expect(
        formatAgo(now.subtract(const Duration(hours: 3)), now: now),
        '3 h ago',
      );
    });

    test('falls back to the full date after a day', () {
      final old = now.subtract(const Duration(hours: 30));
      expect(formatAgo(old, now: now), formatDateTime(old));
    });
  });

  group('server editor', () {
    Future<void> openAdd(WidgetTester tester) async {
      await pumpApp(tester, server: FakeMcpServer());
      await goTo(tester, '/mcp-servers');
      await tester.tap(find.text('Add your first server'));
      await tester.pumpAndSettle();
    }

    testWidgets('closes straight away when nothing was typed', (tester) async {
      await openAdd(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('Add MCP server'), findsNothing);
    });

    testWidgets('asks before throwing away edits, and can keep them', (
      tester,
    ) async {
      await openAdd(tester);
      await tester.enterText(_field('Name'), 'Draft');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Add MCP server'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget, reason: 'the text is kept');

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Add MCP server'), findsNothing);
    });

    testWidgets('clicking outside the dialog asks too', (tester) async {
      await openAdd(tester);
      await tester.enterText(_field('Name'), 'Draft');

      // The barrier, Escape and the back gesture all end in Navigator.maybePop.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Add MCP server'), findsOneWidget);
    });

    testWidgets('saving does not ask', (tester) async {
      await openAdd(tester);
      await tester.enterText(_field('Name'), 'Demo');
      await tester.enterText(_field('Endpoint URL'), 'mcp.test/mcp');
      await tester.tap(find.text('Add & connect'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('Add MCP server'), findsNothing);
      expect(find.text('Demo'), findsOneWidget);
    });
  });

  group('server cards', () {
    testWidgets('a failed server has a Retry button that reconnects it', (
      tester,
    ) async {
      var up = false;
      final server = FakeMcpServer();
      final client = MockClient((request) async {
        if (!up) return http.Response('down', 500);
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..body = request.body;
        return http.Response.fromStream(await server.client.send(copy));
      });
      final container = await pumpApp(tester, httpClient: client);
      await container
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Beta', url: 'https://b.test/mcp');
      await goTo(tester, '/mcp-servers');

      expect(find.text('Error'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      up = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('just now'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
