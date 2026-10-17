import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/audit/audit_stats.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/fakes.dart';

final _tools = [
  {
    'name': 'echo',
    'description': 'Echo a message',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'msg': {'type': 'string'},
      },
    },
    'annotations': {'readOnlyHint': true},
  },
];

void main() {
  test(
    'addServer connects, discovers tools and audits the connection',
    () async {
      final server = FakeMcpServer(tools: _tools);
      final container = await makeContainer(server: server);
      addTearDown(container.dispose);

      final hub = container.read(mcpHubProvider.notifier);
      final runtime = await hub.addServer(
        name: 'Demo',
        url: 'https://mcp.test/mcp',
      );

      expect(runtime.status, ServerStatus.connected);
      expect(runtime.tools.map((t) => t.name), ['echo']);
      expect(runtime.info!.name, 'fake');

      final audit = container.read(auditLogProvider);
      expect(audit, hasLength(1));
      expect(audit.single.kind, AuditKind.serverConnect);
      expect(audit.single.status, AuditStatus.success);
    },
  );

  test('connection failures are surfaced and audited', () async {
    final container = await makeContainer(
      httpClient: MockClient(
        (_) async => throw http.ClientException('connection refused'),
      ),
    );
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Bad',
      url: 'https://down.test/mcp',
    );

    expect(runtime.status, ServerStatus.error);
    expect(runtime.error, contains('Could not reach'));
    expect(runtime.tools, isEmpty);
    final event = container.read(auditLogProvider).single;
    expect(event.kind, AuditKind.serverConnect);
    expect(event.status, AuditStatus.error);
  });

  test('configs persist and reload on next start', () async {
    final server = FakeMcpServer(tools: _tools);
    final first = await makeContainer(server: server);
    await first
        .read(mcpHubProvider.notifier)
        .addServer(
          name: 'Demo',
          url: 'https://mcp.test/mcp',
          headers: {'Authorization': 'Bearer abc'},
        );
    final stored = first.read(mcpHubProvider).servers.single.config;

    // Second container sharing the same persisted prefs.
    final prefs = <String, Object>{
      'mcpm.servers.v1': '[${_json(stored.toJson())}]',
    };
    final second = await makeContainer(
      server: FakeMcpServer(tools: _tools),
      prefs: prefs,
    );
    addTearDown(second.dispose);
    final state = second.read(mcpHubProvider);
    expect(state.servers.single.config.name, 'Demo');
    expect(state.servers.single.config.headers['Authorization'], 'Bearer abc');

    // Enabled servers reconnect automatically on startup.
    await pumpEventQueue();
    expect(
      second.read(mcpHubProvider).servers.single.status,
      ServerStatus.connected,
    );
    first.dispose();
  });

  test('callTool records a redacted audit event with provenance', () async {
    final server = FakeMcpServer(
      tools: _tools,
      handlers: {'echo': (args) => textResult('echo ${args['msg']}')},
    );
    final container = await makeContainer(server: server);
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Demo',
      url: 'https://mcp.test/mcp',
    );

    final result = await hub.callTool(
      serverId: runtime.config.id,
      toolName: 'echo',
      args: {'msg': 'hi', 'apiKey': 'super-secret'},
      source: AuditSource.operator,
      actor: 'operator:gemma4',
      approval: 'user',
    );
    expect(result.text, 'echo hi');

    final event = container.read(auditLogProvider).first;
    expect(event.kind, AuditKind.toolCall);
    expect(event.status, AuditStatus.success);
    expect(event.actor, 'operator:gemma4');
    expect(event.approval, 'user');
    expect(event.serverName, 'Demo');
    expect(event.args, isNot(contains('super-secret')));
    expect(event.args, contains('[redacted]'));
    expect(event.result, contains('echo hi'));
  });

  test(
    'tool errors and unknown servers are audited as errors, not thrown',
    () async {
      final server = FakeMcpServer(
        tools: _tools,
        handlers: {'echo': (_) => textResult('bad input', isError: true)},
      );
      final container = await makeContainer(server: server);
      addTearDown(container.dispose);
      final hub = container.read(mcpHubProvider.notifier);
      final runtime = await hub.addServer(
        name: 'Demo',
        url: 'https://mcp.test/mcp',
      );

      final failed = await hub.callTool(
        serverId: runtime.config.id,
        toolName: 'echo',
        args: {},
        source: AuditSource.workbench,
        actor: 'user',
      );
      expect(failed.isError, isTrue);

      final missing = await hub.callTool(
        serverId: 'nope',
        toolName: 'echo',
        args: {},
        source: AuditSource.workbench,
        actor: 'user',
      );
      expect(missing.isError, isTrue);
      expect(missing.text, contains('not connected'));

      final statuses = container
          .read(auditLogProvider)
          .where((e) => e.kind == AuditKind.toolCall)
          .map((e) => e.status);
      expect(statuses, [AuditStatus.error, AuditStatus.error]);
    },
  );

  test('disabling a server removes its tools from availableTools', () async {
    final container = await makeContainer(server: FakeMcpServer(tools: _tools));
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Demo',
      url: 'https://mcp.test/mcp',
    );
    expect(container.read(mcpHubProvider).availableTools, hasLength(1));

    await hub.setEnabled(runtime.config.id, false);
    expect(container.read(mcpHubProvider).availableTools, isEmpty);
    expect(
      container.read(mcpHubProvider).byId(runtime.config.id)!.status,
      ServerStatus.disabled,
    );
  });

  test('audit log is capped and newest first', () async {
    final container = await makeContainer();
    addTearDown(container.dispose);
    final log = container.read(auditLogProvider.notifier);
    for (var i = 0; i < auditCapacity + 25; i++) {
      log.record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.workbench,
        actor: 'user',
        toolName: 't$i',
      );
    }
    final events = container.read(auditLogProvider);
    expect(events, hasLength(auditCapacity));
    expect(events.first.toolName, 't${auditCapacity + 24}');
  });

  test('AuditStats buckets by hour and computes latency', () {
    final now = DateTime(2026, 10, 17, 15, 30);
    AuditEvent ev(DateTime t, AuditStatus s, int ms) => AuditEvent(
      id: '${t.microsecondsSinceEpoch}$s',
      timestamp: t,
      kind: AuditKind.toolCall,
      status: s,
      source: AuditSource.workbench,
      actor: 'user',
      serverName: 'S',
      toolName: 'T',
      durationMs: ms,
    );
    final stats = AuditStats.compute([
      ev(DateTime(2026, 10, 17, 15, 10), AuditStatus.success, 100),
      ev(DateTime(2026, 10, 17, 15, 20), AuditStatus.error, 300),
      ev(DateTime(2026, 10, 17, 14, 5), AuditStatus.denied, 0),
      ev(DateTime(2026, 10, 15, 9), AuditStatus.success, 50), // outside window
    ], now: now);

    expect(stats.total, 3);
    expect((stats.success, stats.error, stats.denied), (1, 1, 1));
    expect(stats.avgLatencyMs, 200); // denied calls have no latency
    expect(stats.hourly, hasLength(24));
    expect(stats.hourly.last.start.hour, 15);
    expect(stats.hourly.last.total, 2);
    expect(stats.hourly[22].denied, 1);
    expect(stats.topTools.single.key, 'S · T');
    expect(stats.topTools.single.value, 3);
  });
}

String _json(Object o) => jsonEncode(o);
