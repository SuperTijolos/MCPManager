import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/fakes.dart';

enum _Mode {
  /// Everything works.
  up,

  /// The network is gone.
  down,

  /// Only `ping` fails at the network level; reconnecting works.
  flakyPing,

  /// The server has no `ping` method and says so with a JSON-RPC error.
  noPing,
}

/// A fake MCP server whose behaviour can be switched mid-test.
class _Switchable {
  final server = FakeMcpServer();
  _Mode mode = _Mode.up;
  int initializes = 0;

  http.Client get client => MockClient((request) async {
    final method = request.method == 'POST'
        ? (jsonDecode(request.body) as Map)['method']
        : null;
    final id = request.method == 'POST'
        ? (jsonDecode(request.body) as Map)['id']
        : null;
    if (method == 'initialize') initializes++;
    if (mode == _Mode.down) throw http.ClientException('connection refused');
    if (method == 'ping') {
      if (mode == _Mode.flakyPing) {
        throw http.ClientException('connection reset');
      }
      if (mode == _Mode.noPing) {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Method not found'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
    }
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..body = request.body;
    return http.Response.fromStream(await server.client.send(copy));
  });
}

void main() {
  late _Switchable remote;
  late ProviderContainer container;
  late McpHub hub;

  McpHubState state() => container.read(mcpHubProvider);
  List<AuditEvent> audit() => container.read(auditLogProvider);

  Future<void> connected() async {
    remote = _Switchable();
    container = await makeContainer(httpClient: remote.client);
    addTearDown(container.dispose);
    hub = container.read(mcpHubProvider.notifier);
    await hub.addServer(name: 'Demo', url: 'https://mcp.test/mcp');
    expect(state().servers.single.status, ServerStatus.connected);
  }

  test('a healthy server only gets its "checked" time refreshed', () async {
    await connected();
    final before = state().servers.single.checkedAt!;
    final initializes = remote.initializes;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    await hub.checkHealth();

    final after = state().servers.single;
    expect(after.status, ServerStatus.connected);
    expect(after.checkedAt!.isAfter(before), isTrue);
    expect(remote.initializes, initializes, reason: 'no reconnect');
    expect(audit(), hasLength(1), reason: 'only the original connect');
  });

  test('a server without ping still counts as alive', () async {
    await connected();
    final initializes = remote.initializes;
    remote.mode = _Mode.noPing;

    await hub.checkHealth();

    expect(state().servers.single.status, ServerStatus.connected);
    expect(remote.initializes, initializes);
    expect(audit(), hasLength(1));
  });

  test(
    'a server that went away is marked down once, not on every check',
    () async {
      await connected();
      remote.mode = _Mode.down;

      await hub.checkHealth();

      final runtime = state().servers.single;
      expect(runtime.status, ServerStatus.error);
      expect(runtime.tools, isEmpty);
      expect(state().availableTools, isEmpty);
      expect(audit(), hasLength(2));
      expect(audit().first.kind, AuditKind.serverConnect);
      expect(audit().first.status, AuditStatus.error);

      await hub.checkHealth();
      await hub.checkHealth();
      expect(audit(), hasLength(2), reason: 'an outage is not re-reported');
    },
  );

  test('a blip heals itself by reconnecting', () async {
    await connected();
    final initializes = remote.initializes;
    remote.mode = _Mode.flakyPing;

    await hub.checkHealth();

    expect(state().servers.single.status, ServerStatus.connected);
    expect(remote.initializes, initializes + 1);
    expect(audit().first.status, AuditStatus.success);
  });

  test('reconnectUnavailable retries only servers that are down', () async {
    await connected();
    remote.mode = _Mode.down;
    await hub.addServer(name: 'Other', url: 'https://other.test/mcp');
    final down = state().unavailable;
    expect(down.map((s) => s.config.name), ['Other']);

    remote.mode = _Mode.up;
    final initializes = remote.initializes;
    await hub.reconnectUnavailable();

    expect(state().unavailable, isEmpty);
    expect(remote.initializes, initializes + 1, reason: 'only Other retried');
  });
}
