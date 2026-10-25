import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/audit/audit_stats.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_portal_server/mcp_portal_server.dart'
    show GatewayAuditEvent;

import '../support/fakes.dart';
import '../support/gateway_harness.dart';

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
      expect(audit.single.source, AuditSource.system);
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

  test('servers live on the server and reload on next start', () async {
    final gateway = await TestGateway.start(
      upstream: FakeMcpServer(tools: _tools),
    );
    final first = await makeContainer(gateway: gateway);
    await first
        .read(mcpHubProvider.notifier)
        .addServer(
          name: 'Demo',
          url: 'https://mcp.test/mcp',
          headers: {'Authorization': 'Bearer abc'},
        );
    first.dispose();

    // A new session on the same server: nothing is kept in the browser.
    final second = await makeContainer(gateway: gateway);
    addTearDown(second.dispose);
    final hub = second.read(mcpHubProvider.notifier);
    await hub.loaded;
    final state = second.read(mcpHubProvider);
    expect(state.servers.single.config.name, 'Demo');
    // The server never sends a header value back, only that there is one.
    expect(state.servers.single.config.headers.keys, ['Authorization']);
    expect(
      state.servers.single.config.headers['Authorization'],
      maskedHeaderValue,
    );
    expect(state.servers.single.status, ServerStatus.connected);
    expect(gateway.state.servers.single.headers['Authorization'], 'Bearer abc');
  });

  test('editing leaves a masked header alone and changes the others', () async {
    final container = await makeContainer(server: FakeMcpServer(tools: _tools));
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Demo',
      url: 'https://mcp.test/mcp',
      headers: {'Authorization': 'Bearer abc', 'X-Team': 'one'},
    );
    final stored = container.read(mcpHubProvider).servers.single.config;
    expect(stored.headers.values.toSet(), {maskedHeaderValue});

    await hub.updateServer(
      stored.copyWith(headers: {...stored.headers, 'X-Team': 'two'}),
    );
    final gateway = gatewayOf(container);
    expect(gateway.state.server(runtime.config.id)!.headers, {
      'Authorization': 'Bearer abc',
      'X-Team': 'two',
    });
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
    expect(event.source, AuditSource.operator);
    expect(event.serverName, 'Demo');
    expect(event.args, isNot(contains('super-secret')));
    expect(event.args, contains('[redacted]'));
    expect(event.result, contains('echo hi'));
  });

  test('a call from the Tools page is recorded as the workbench\'s', () async {
    final container = await makeContainer(
      server: FakeMcpServer(
        tools: _tools,
        handlers: {'echo': (_) => textResult('ok')},
      ),
    );
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Demo',
      url: 'https://mcp.test/mcp',
    );
    await hub.callTool(
      serverId: runtime.config.id,
      toolName: 'echo',
      args: {},
      source: AuditSource.workbench,
      actor: 'user',
    );
    final event = container.read(auditLogProvider).first;
    expect(event.source, AuditSource.workbench);
    expect(event.actor, 'user');
    expect(event.conversationId, isNull);
  });

  test(
    'tool errors are audited as errors and unknown servers do not throw',
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
      expect(failed.text, 'bad input');

      final missing = await hub.callTool(
        serverId: 'nope',
        toolName: 'echo',
        args: {},
        source: AuditSource.workbench,
        actor: 'user',
      );
      expect(missing.isError, isTrue);
      expect(missing.text, isNotEmpty);

      final calls = container
          .read(auditLogProvider)
          .where((e) => e.kind == AuditKind.toolCall);
      expect(calls.map((e) => e.status), [AuditStatus.error]);
    },
  );

  test('a call the server cannot make says why instead of throwing', () async {
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
    final result = await hub.callTool(
      serverId: runtime.config.id,
      toolName: 'echo',
      args: {},
      source: AuditSource.workbench,
      actor: 'user',
    );
    expect(result.isError, isTrue);
    expect(result.text, contains('Could not reach'));
  });

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

  test('removing a server removes it from the server', () async {
    final container = await makeContainer(server: FakeMcpServer(tools: _tools));
    addTearDown(container.dispose);
    final hub = container.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Demo',
      url: 'https://mcp.test/mcp',
    );
    await hub.removeServer(runtime.config.id);
    expect(container.read(mcpHubProvider).servers, isEmpty);
    expect(gatewayOf(container).state.servers, isEmpty);
  });

  test(
    'the audit log shows the newest events first, up to its capacity',
    () async {
      final container = await makeContainer();
      addTearDown(container.dispose);
      final gateway = gatewayOf(container);
      for (var i = 0; i < auditCapacity + 25; i++) {
        await gateway.server.audit.record(
          GatewayAuditEvent(
            id: 'e$i',
            timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
            source: 'dashboard',
            principal: const {'kind': 'admin', 'id': 'admin', 'name': 'Admin'},
            status: 'success',
            tool: 't$i',
          ),
        );
      }
      final log = container.read(auditLogProvider.notifier);
      await log.reload();
      final events = container.read(auditLogProvider);
      expect(events, hasLength(auditCapacity));
      expect(events.first.toolName, 't${auditCapacity + 24}');
    },
  );

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
    expect(stats.hourly.last.start.hour, 14); // rolling hour ends at 15:30
    expect(stats.hourly.last.total, 2);
    expect(stats.hourly[22].denied, 1);
    expect(stats.topTools.single.key, 'S · T');
    expect(stats.topTools.single.value, 3);
  });
  test('rolling stats include the first partial hour', () {
    final now = DateTime(2026, 10, 17, 15, 30);
    final event = AuditEvent(
      id: 'boundary',
      timestamp: DateTime(2026, 10, 16, 15, 45),
      kind: AuditKind.toolCall,
      status: AuditStatus.success,
      source: AuditSource.workbench,
      actor: 'user',
      serverName: 'S',
      toolName: 'T',
    );
    final stats = AuditStats.compute([event], now: now);
    expect(stats.total, 1);
    expect(stats.hourly.first.start.hour, 15);
    expect(stats.hourly.first.start.minute, 30);
    expect(stats.hourly.first.success, 1);
  });
}
