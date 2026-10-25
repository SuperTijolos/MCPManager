import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_auto_connection.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_sse_client.dart';

import '../support/fakes.dart';

final _tools = [
  {
    'name': 'get_active_file',
    'description': 'Current file',
    'inputSchema': {'type': 'object'},
    'annotations': {'readOnlyHint': true},
  },
  {
    'name': 'slow',
    'description': 'Slow tool',
    'inputSchema': {'type': 'object'},
  },
  {
    'name': 'fast',
    'description': 'Fast tool',
    'inputSchema': {'type': 'object'},
  },
];

FakeSseServer _server({String? token, int? chunk, String? endpoint}) =>
    FakeSseServer(
      tools: _tools,
      requireToken: token,
      chunkSize: chunk,
      endpointOverride: endpoint,
      handlers: {
        'get_active_file': (args) => textResult('lib/main.dart'),
        'slow': (_) => textResult('slow done'),
        'fast': (_) => textResult('fast done'),
      },
      replyDelays: {'slow': const Duration(milliseconds: 60)},
    );

McpServerConfig _config(
  String url, {
  Map<String, String> headers = const {},
  McpTransport transport = McpTransport.sse,
}) => McpServerConfig(
  id: 's',
  name: 'Bridge',
  url: url,
  headers: headers,
  transport: transport,
);

/// Model BrowserClient's failure when cancelling an already-aborted fetch
/// reader. A cleanup Future is allowed to fail even after a healthy session.
http.Client _rejectingCancelClient(FakeSseServer server) =>
    MockClient.streaming((request, bodyStream) async {
      final response = await forwardTo(server.client, request, bodyStream);
      if (request.method != 'GET' || request.url.path != '/sse') {
        return response;
      }
      late final StreamSubscription<List<int>> inner;
      final relay = StreamController<List<int>>(
        sync: true,
        onCancel: () async {
          await inner.cancel();
          throw StateError('ReadableStream reader.cancel() rejected');
        },
      );
      inner = response.stream.listen(
        relay.add,
        onError: relay.addError,
        onDone: relay.close,
      );
      return http.StreamedResponse(
        relay.stream,
        response.statusCode,
        headers: response.headers,
      );
    });

void main() {
  group('McpSseClient (legacy HTTP+SSE)', () {
    test(
      'handshake: GET /sse, endpoint event, POST initialize, then initialized',
      () async {
        final server = _server(token: 'tok');
        final client = McpSseClient(
          _config(
            'http://localhost:3333/sse',
            headers: {'Authorization': 'Bearer tok'},
          ),
          httpClient: server.client,
        );
        final info = await client.connect();

        expect(info.name, 'vscode-mcp-bridge');
        expect(info.version, '0.2.5');
        expect(client.isConnected, isTrue);
        expect(client.transport, McpTransport.sse);
        expect(server.log, [
          'GET /sse', // exact path: this server 404s on a query string
          'POST /messages?sessionId=s1',
          'POST /messages?sessionId=s1',
        ]);
        expect(server.posts.map((p) => p['method']), [
          'initialize',
          'notifications/initialized',
        ]);
        expect(
          server.authHeaders,
          everyElement('Bearer tok'),
          reason: 'the token goes on the stream and on every POST',
        );
        client.close();
      },
    );

    test('lists tools and calls them; errors surface', () async {
      final server = _server();
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      await client.connect();

      final tools = await client.listTools();
      expect(tools.map((t) => t.name), ['get_active_file', 'slow', 'fast']);
      expect(tools.first.isReadOnly, isTrue);

      final result = await client.callTool('get_active_file', {});
      expect(result.text, 'lib/main.dart');
      expect(result.isError, isFalse);

      await expectLater(
        client.callTool('nope', {}),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      client.close();
    });

    test('parses events split across arbitrary network chunks', () async {
      final server = _server(chunk: 3);
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      await client.connect();
      expect((await client.listTools()).length, 3);
      expect((await client.callTool('fast', {})).text, 'fast done');
      client.close();
    });

    test('replies are matched to requests by id, even out of order', () async {
      final server = _server();
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      await client.connect();

      final slow = client.callTool('slow', {}); // answered 60 ms later
      final fast = client.callTool('fast', {}); // answered immediately

      expect((await fast).text, 'fast done');
      expect((await slow).text, 'slow done');
      client.close();
    });

    test(
      'refuses an endpoint on another origin and never sends credentials there',
      () async {
        final server = _server(
          token: 'tok',
          endpoint: 'http://evil.test/messages?sessionId=s1',
        );
        final client = McpSseClient(
          _config(
            'http://localhost:3333/sse',
            headers: {'Authorization': 'Bearer tok'},
          ),
          httpClient: server.client,
        );
        await expectLater(
          client.connect(),
          throwsA(
            isA<McpException>().having(
              (e) => e.message,
              'message',
              contains('different origin'),
            ),
          ),
        );
        expect(server.posts, isEmpty);
        expect(server.log.where((l) => l.startsWith('POST')), isEmpty);
      },
    );

    test('accepts an absolute endpoint on the same origin', () async {
      final server = _server(
        endpoint: 'http://localhost:3333/messages?sessionId=s1',
      );
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      expect((await client.connect()).name, 'vscode-mcp-bridge');
      client.close();
    });

    test('a missing token is reported with what to do about it', () async {
      final server = _server(token: 'tok');
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      await expectLater(
        client.connect(),
        throwsA(
          isA<McpAuthRequired>().having(
            (e) => e.message,
            'message',
            contains('bearer token'),
          ),
        ),
      );
    });

    test('a wrong static token says to check it', () async {
      final server = _server(token: 'tok');
      final client = McpSseClient(
        _config(
          'http://localhost:3333/sse',
          headers: {'Authorization': 'Bearer wrong'},
        ),
        httpClient: server.client,
      );
      await expectLater(
        client.connect(),
        throwsA(
          isA<McpAuthRequired>().having(
            (e) => e.message,
            'message',
            contains('Check the server headers/token'),
          ),
        ),
      );
    });

    test(
      'an OAuth token provider is refreshed once on 401, then retried',
      () async {
        final server = _server(token: 'fresh');
        final asked = <bool>[];
        var current = 'stale';
        final client = McpSseClient(
          _config('http://localhost:3333/sse'),
          httpClient: server.client,
          // Like the real provider: a refresh replaces the stored token.
          tokenProvider: ({bool forceRefresh = false}) async {
            asked.add(forceRefresh);
            if (forceRefresh) current = 'fresh';
            return current;
          },
        );
        await client.connect();
        expect(client.isConnected, isTrue);
        expect(asked.where((f) => f), hasLength(1));
        client.close();
      },
    );

    test('the wrong path is a 404 the caller can act on', () async {
      final server = _server();
      final client = McpSseClient(
        _config('http://localhost:3333/mcp'),
        httpClient: server.client,
      );
      await expectLater(
        client.connect(),
        throwsA(isA<McpException>().having((e) => e.code, 'code', 404)),
      );
    });

    test(
      'a stream that never announces an endpoint times out clearly',
      () async {
        final server = FakeSseServer(silent: true);
        final client = McpSseClient(
          _config('http://localhost:3333/sse'),
          httpClient: server.client,
          endpointTimeout: const Duration(milliseconds: 150),
        );
        await expectLater(
          client.connect(),
          throwsA(
            isA<McpException>().having(
              (e) => e.message,
              'message',
              contains('never sent an "endpoint" event'),
            ),
          ),
        );
      },
    );

    test('a dropped stream reconnects on the next call', () async {
      final server = _server();
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      await client.connect();
      server.dropStream();
      await pumpEventQueue();
      expect(client.isConnected, isFalse);

      final result = await client.callTool('fast', {});
      expect(result.text, 'fast done');
      expect(server.sessions, 2, reason: 'a new session was opened');
      expect(client.isConnected, isTrue);
      client.close();
    });

    test(
      'rejected reader cancellation never becomes an unhandled async error',
      () async {
        final server = _server();
        final client = McpSseClient(
          _config('http://localhost:3333/sse'),
          httpClient: _rejectingCancelClient(server),
        );
        await client.connect();
        // Reconnect tears down the prior stream; its async cancel() rejects.
        await client.connect();
        expect(client.isConnected, isTrue);
        expect(server.sessions, 2);
        // Closing the second stream must swallow the same cleanup error.
        client.close();
        await pumpEventQueue();
        expect(client.isConnected, isFalse);
        expect(server.streamsCancelled, 2);
      },
    );

    test(
      'a failed SSE read cancels safely and the next request reconnects',
      () async {
        final server = _server();
        final client = McpSseClient(
          _config('http://localhost:3333/sse'),
          httpClient: _rejectingCancelClient(server),
        );
        await client.connect();
        server.failStream(StateError('The browser stream lost its connection'));
        await pumpEventQueue();
        expect(client.isConnected, isFalse);
        expect(server.streamsCancelled, 1);

        expect((await client.callTool('fast', {})).text, 'fast done');
        expect(server.sessions, 2);
        client.close();
        await pumpEventQueue();
        expect(server.streamsCancelled, 2);
      },
    );

    test('close() cancels the stream', () async {
      final server = _server();
      final client = McpSseClient(
        _config('http://localhost:3333/sse'),
        httpClient: server.client,
      );
      await client.connect();
      client.close();
      await pumpEventQueue();
      expect(client.isConnected, isFalse);
      expect(server.streamsCancelled, 1);
    });

    test(
      'a request in flight when the stream drops fails instead of hanging',
      () async {
        final server = _server();
        final client = McpSseClient(
          _config('http://localhost:3333/sse'),
          httpClient: server.client,
        );
        await client.connect();
        final call = client.callTool('slow', {}); // reply is 60 ms away
        await pumpEventQueue();
        server.dropStream();
        await expectLater(call, throwsA(isA<McpException>()));
        client.close();
      },
    );
  });

  group('connectionCandidates', () {
    String show(McpServerConfig c) =>
        connectionCandidates(c)
            .map((a) => '${a.transport.wire} ${a.url}')
            .join(' | ');

    test('explicit transports are used as given', () {
      expect(
        show(_config('http://h:1/x', transport: McpTransport.sse)),
        'sse http://h:1/x',
      );
      expect(
        show(_config('http://h:1/x', transport: McpTransport.streamableHttp)),
        'streamable-http http://h:1/x',
      );
    });

    test('a /sse URL tries the legacy transport first', () {
      expect(
        show(_config('http://h:1/sse', transport: McpTransport.auto)),
        'sse http://h:1/sse | streamable-http http://h:1/sse | '
        'streamable-http http://h:1/mcp',
      );
    });

    test('a normal path tries Streamable HTTP, then SSE', () {
      expect(
        show(_config('http://h:1/api', transport: McpTransport.auto)),
        'streamable-http http://h:1/api | sse http://h:1/api',
      );
    });

    test('a bare host:port also tries /mcp and /sse', () {
      expect(
        show(_config('http://localhost:3333', transport: McpTransport.auto)),
        'streamable-http http://localhost:3333 | sse http://localhost:3333 | '
        'streamable-http http://localhost:3333/mcp | sse http://localhost:3333/sse',
      );
    });
  });

  group('auto-detection through the hub', () {
    test('bare localhost:3333 on a bridge that only serves /sse: connects, remembers /sse', () async {
      final server = _server(token: 'tok');
      final c = await makeContainer(httpClient: server.client);
      addTearDown(c.dispose);
      final hub = c.read(mcpHubProvider.notifier);

      final runtime = await hub.addServer(
        name: 'VS Code',
        url: 'http://localhost:3333',
        headers: {'Authorization': 'Bearer tok'},
      );

      expect(runtime.status, ServerStatus.connected);
      expect(runtime.tools.map((t) => t.name), contains('get_active_file'));
      expect(runtime.config.url, 'http://localhost:3333/sse');
      expect(runtime.config.transport, McpTransport.sse);

      // And it keeps working, including a tool call over the SSE session.
      final result = await hub.callTool(
        serverId: runtime.config.id,
        toolName: 'get_active_file',
        args: {},
        source: AuditSource.workbench,
        actor: 'user',
      );
      expect(result.text, 'lib/main.dart');
      expect(
        c.read(auditLogProvider).where((e) => e.status == AuditStatus.error),
        isEmpty,
      );
    });

    test('once detected, the next connect goes directly', () async {
      final bridge = _server(token: 'tok');
      final c = await makeContainer(httpClient: bridge.client);
      addTearDown(c.dispose);
      final hub = c.read(mcpHubProvider.notifier);
      final runtime = await hub.addServer(
        name: 'VS Code',
        url: 'http://localhost:3333',
        headers: {'Authorization': 'Bearer tok'},
      );
      expect(runtime.config.transport, McpTransport.sse);

      // The server remembers what worked, so it connects there from now on.
      final saved = gatewayOf(c).state.server(runtime.config.id)!;
      expect(saved.url, 'http://localhost:3333/sse');
      expect(saved.transport, McpTransport.sse);

      final mark = bridge.log.length;
      await hub.connect(runtime.config.id);
      final since = bridge.log.sublist(mark);
      expect(
        c.read(mcpHubProvider).servers.single.status,
        ServerStatus.connected,
      );
      expect(since.first, 'GET /sse', reason: 'no wasted POST attempts');
      expect(since.where((l) => l.startsWith('POST /sse')), isEmpty);
    });

    test(
      'a URL that already ends in /sse goes straight to the legacy transport',
      () async {
        final server = _server();
        final c = await makeContainer(httpClient: server.client);
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Bridge', url: 'http://localhost:3333/sse');
        expect(runtime.status, ServerStatus.connected);
        expect(server.log.first, 'GET /sse');
        expect(server.log.any((l) => l == 'POST /sse'), isFalse);
      },
    );

    test(
      'Streamable HTTP servers are still found first and never touch /sse',
      () async {
        final mcp = FakeMcpServer(tools: _tools);
        final c = await makeContainer(server: mcp);
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Modern', url: 'https://mcp.test/mcp');
        expect(runtime.status, ServerStatus.connected);
        expect(runtime.config.transport, McpTransport.streamableHttp);
        expect(runtime.config.url, 'https://mcp.test/mcp');
      },
    );

    test(
      'the token requirement stops the search: no pointless fallbacks',
      () async {
        final server = _server(token: 'tok');
        final c = await makeContainer(httpClient: server.client);
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'VS Code', url: 'http://localhost:3333');

        expect(runtime.status, ServerStatus.needsAuth);
        expect(runtime.error, contains('bearer token'));
        expect(server.log, hasLength(1), reason: 'one 401 is the answer');
      },
    );

    test(
      'when nothing works the error lists every attempt and the usual paths',
      () async {
        final c = await makeContainer(
          httpClient: MockClient((_) async => http.Response('', 404)),
        );
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Nothing', url: 'http://localhost:9999');

        expect(runtime.status, ServerStatus.error);
        expect(runtime.error, contains('No MCP transport worked'));
        expect(
          runtime.error,
          contains('Streamable HTTP at http://localhost:9999/mcp'),
        );
        expect(
          runtime.error,
          contains('Legacy SSE at http://localhost:9999/sse'),
        );
        expect(runtime.error, contains('/mcp'));
      },
    );

    test('an explicit transport is not second-guessed', () async {
      final server = _server();
      final c = await makeContainer(httpClient: server.client);
      addTearDown(c.dispose);
      final runtime = await c
          .read(mcpHubProvider.notifier)
          .addServer(
            name: 'Forced',
            url: 'http://localhost:3333/sse',
            transport: McpTransport.streamableHttp,
          );
      expect(runtime.status, ServerStatus.error);
      expect(runtime.error, contains('HTTP 404'));
      expect(server.log.where((l) => l.startsWith('GET')), isEmpty);
    });

    test(
      'a network failure is reported as such, not retried on other paths',
      () async {
        var calls = 0;
        final c = await makeContainer(
          httpClient: MockClient((_) async {
            calls++;
            throw http.ClientException('connection refused');
          }),
        );
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Down', url: 'http://localhost:3333');
        expect(runtime.status, ServerStatus.error);
        expect(runtime.error, contains('Could not reach'));
        expect(calls, 1);
      },
    );
  });
}
