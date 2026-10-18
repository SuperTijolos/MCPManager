import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/audit/audit_stats.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

AuditEvent _event(DateTime at, [String id = 'e']) => AuditEvent(
  id: id,
  timestamp: at,
  kind: AuditKind.toolCall,
  status: AuditStatus.success,
  source: AuditSource.workbench,
  actor: 'user',
  serverName: 'Example',
  toolName: 'lookup',
);

/// A MockClient hands over finalized requests, so copy before forwarding.
Future<http.Response> _forward(
  FakeMcpServer server,
  http.Request request,
) async {
  final copy = http.Request(request.method, request.url)
    ..headers.addAll(request.headers)
    ..body = request.body;
  return http.Response.fromStream(await server.client.send(copy));
}

/// `a.test` always answers; `b.test` fails until [bUp] is set.
class _TwoServers {
  final a = FakeMcpServer();
  final b = FakeMcpServer();
  bool bUp = false;

  http.Client get client => MockClient((request) async {
    if (request.url.host == 'a.test') {
      return _forward(a, request);
    }
    if (!bUp) return http.Response('down', 500);
    return _forward(b, request);
  });
}

void main() {
  group('AuditStats.truncatedSince', () {
    final now = DateTime(2026, 1, 10, 12);

    test('is null while the log has room', () {
      final events = [_event(now.subtract(const Duration(minutes: 1)))];
      expect(
        AuditStats.truncatedSince(
          events,
          capacity: 3,
          window: const Duration(hours: 24),
          now: now,
        ),
        isNull,
      );
    });

    test('is null when the full log still reaches back past the window', () {
      final events = [
        _event(now.subtract(const Duration(hours: 1)), 'new'),
        _event(now.subtract(const Duration(hours: 30)), 'old'),
      ];
      expect(
        AuditStats.truncatedSince(
          events,
          capacity: 2,
          window: const Duration(hours: 24),
          now: now,
        ),
        isNull,
      );
    });

    test(
      'reports the oldest record when a full log starts inside the window',
      () {
        final oldest = now.subtract(const Duration(hours: 5));
        final events = [
          _event(now.subtract(const Duration(hours: 1)), 'new'),
          _event(oldest, 'old'),
        ];
        expect(
          AuditStats.truncatedSince(
            events,
            capacity: 2,
            window: const Duration(hours: 24),
            now: now,
          ),
          oldest,
        );
      },
    );
  });

  group('Overview', () {
    testWidgets('a failed server can be retried from the attention card', (
      tester,
    ) async {
      final servers = _TwoServers();
      final container = await pumpApp(tester, httpClient: servers.client);
      await container
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Beta', url: 'https://b.test/mcp');
      await goTo(tester, '/');

      expect(find.text('Some connections need attention'), findsOneWidget);
      expect(find.text('1 need attention'), findsOneWidget);
      expect(find.text('Retry'), findsWidgets);

      servers.bUp = true;
      await tester.tap(find.text('Retry').first);
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsNothing);
      expect(find.text('Workspace ready'), findsOneWidget);
      expect(find.text('All servers connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh only retries servers that are down', (tester) async {
      final servers = _TwoServers();
      final container = await pumpApp(tester, httpClient: servers.client);
      final hub = container.read(mcpHubProvider.notifier);
      await hub.addServer(name: 'Alpha', url: 'https://a.test/mcp');
      await hub.addServer(name: 'Beta', url: 'https://b.test/mcp');
      await goTo(tester, '/');
      final healthyRequests = servers.a.requests.length;
      expect(healthyRequests, greaterThan(0));

      servers.bUp = true;
      await tester.tap(find.byTooltip('Retry servers that are not connected'));
      await tester.pumpAndSettle();

      expect(
        container
            .read(mcpHubProvider)
            .byId(container.read(mcpHubProvider).servers[1].config.id)!
            .status,
        ServerStatus.connected,
      );
      expect(
        servers.a.requests.length,
        healthyRequests,
        reason: 'the healthy server keeps its session',
      );
      // With everything up the same button re-checks every server.
      expect(find.byTooltip('Re-check enabled servers'), findsOneWidget);
      await tester.tap(find.byTooltip('Re-check enabled servers'));
      await tester.pumpAndSettle();
      expect(servers.a.requests.length, greaterThan(healthyRequests));
      expect(tester.takeException(), isNull);
    });

    testWidgets('warns when a full audit log cuts the selected window short', (
      tester,
    ) async {
      final now = DateTime.now();
      final events = [
        for (var i = 0; i < auditCapacity; i++)
          _event(now.subtract(Duration(seconds: i)), 'e$i').toJson(),
      ];
      await pumpApp(tester, prefs: {'mcpm.audit.v1': jsonEncode(events)});

      await tester.scrollUntilVisible(
        find.textContaining('The audit log is full'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('the last 24h is incomplete'), findsOneWidget);
      expect(
        find.textContaining('Older history may be incomplete'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the generic note while the log has room', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.scrollUntilVisible(
        find.textContaining('Older history may be incomplete'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('The audit log is full'), findsNothing);
    });
  });
}
