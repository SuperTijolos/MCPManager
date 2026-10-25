import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/fakes.dart';

/// A fake MCP server that can be taken away and brought back mid-test.
class _Switchable {
  _Switchable(List<Map<String, dynamic>> tools)
    : server = FakeMcpServer(tools: tools);
  final FakeMcpServer server;
  bool down = false;

  http.Client get client => MockClient((request) async {
    if (down) throw http.ClientException('connection refused');
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..body = request.body;
    return http.Response.fromStream(await server.client.send(copy));
  });
}

final _tools = [
  {
    'name': 'echo',
    'description': 'Echo',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
];

void main() {
  late _Switchable remote;
  late ProviderContainer container;
  late McpHub hub;

  McpHubState state() => container.read(mcpHubProvider);
  List<AuditEvent> audit() => container.read(auditLogProvider);

  Future<void> connected() async {
    remote = _Switchable(_tools);
    container = await makeContainer(httpClient: remote.client);
    addTearDown(container.dispose);
    hub = container.read(mcpHubProvider.notifier);
    await hub.addServer(name: 'Demo', url: 'https://mcp.test/mcp');
    expect(state().servers.single.status, ServerStatus.connected);
  }

  test(
    'a healthy server stays connected and nothing new is reported',
    () async {
      await connected();

      await hub.checkHealth();
      await container.read(auditLogProvider.notifier).catchUp();

      final after = state().servers.single;
      expect(after.status, ServerStatus.connected);
      expect(after.checkedAt, isNotNull);
      expect(after.tools, hasLength(1));
      expect(audit(), hasLength(1), reason: 'only the original connect');
    },
  );

  test(
    'a server that went away is marked down once, not on every check',
    () async {
      await connected();
      remote.down = true;

      await hub.checkHealth();
      await container.read(auditLogProvider.notifier).catchUp();

      final runtime = state().servers.single;
      expect(runtime.status, ServerStatus.error);
      expect(runtime.error, contains('Could not reach'));
      expect(runtime.tools, isEmpty);
      expect(state().availableTools, isEmpty);
      expect(audit(), hasLength(2));
      expect(audit().first.kind, AuditKind.serverConnect);
      expect(audit().first.status, AuditStatus.error);

      await hub.checkHealth();
      await hub.checkHealth();
      await container.read(auditLogProvider.notifier).catchUp();
      expect(audit(), hasLength(2), reason: 'an outage is not re-reported');
    },
  );

  test('a server that comes back is marked up again, once', () async {
    await connected();
    remote.down = true;
    await hub.checkHealth();
    expect(state().servers.single.status, ServerStatus.error);

    remote.down = false;
    await hub.reconnectUnavailable();
    await container.read(auditLogProvider.notifier).catchUp();

    expect(state().unavailable, isEmpty);
    expect(state().servers.single.status, ServerStatus.connected);
    expect(state().availableTools, hasLength(1));
    expect(audit().first.status, AuditStatus.success);
    expect(audit(), hasLength(3));
  });

  test('a server that is down at the start shows why', () async {
    remote = _Switchable(_tools)..down = true;
    container = await makeContainer(httpClient: remote.client);
    addTearDown(container.dispose);
    hub = container.read(mcpHubProvider.notifier);
    await hub.addServer(name: 'Down', url: 'https://mcp.test/mcp');

    final runtime = state().servers.single;
    expect(runtime.status, ServerStatus.error);
    expect(state().unavailable.single.config.name, 'Down');
  });

  test(
    'the server checks health by itself and the dashboard just reloads',
    () async {
      await connected();
      remote.down = true;
      // Whoever asked (a timer on the server, another browser): the result is
      // there for the next reload.
      await gatewayOf(container).server.health.checkAll();
      await hub.refresh();
      expect(state().servers.single.status, ServerStatus.error);
      expect(
        jsonDecode(
          (await gatewayOf(container).client.get(
            Uri.parse('http://gateway.test/api/health'),
            headers: {'authorization': 'Bearer admin-token-for-app-tests-123'},
          )).body,
        )['servers'].values.single['ok'],
        isFalse,
      );
    },
  );
}
