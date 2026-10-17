import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/mcp/mcp_auto_connection.dart';
import 'package:mcp_manager/engine/mcp/mcp_client.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';

import '../support/fakes.dart';

final _tools = [
  {
    'name': 'search_docs',
    'description': 'Search the docs',
    'inputSchema': {'type': 'object'},
    'annotations': {'readOnlyHint': true},
  },
];

McpServerConfig _config(
  String url, {
  McpTransport transport = McpTransport.auto,
}) => McpServerConfig(id: 's', name: 'Edge', url: url, transport: transport);

void main() {
  group('Streamable HTTP session problems are explained, not just "HTTP 404"', () {
    test('the server issues a session the browser cannot read', () async {
      final server = SessionTroubleServer(hideSessionHeader: true);
      final client = McpClient(
        _config('https://cf.test/mcp', transport: McpTransport.streamableHttp),
        httpClient: server.client,
      );

      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>()
              .having((e) => e.code, 'code', 404)
              .having(
                (e) => e.message,
                'message',
                contains('could not read the Mcp-Session-Id'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('Access-Control-Expose-Headers'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('Session expired or does not exist'),
              ),
        ),
      );
      expect(
        client.trace,
        containsAllInOrder([
          'POST initialize → 200',
          contains('session: none'),
          'POST notifications/initialized → 404',
        ]),
      );
    });

    test('the server rejects the session it just created', () async {
      final server = SessionTroubleServer(rejectSession: true);
      final client = McpClient(
        _config('https://cf.test/mcp', transport: McpTransport.streamableHttp),
        httpClient: server.client,
      );

      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>()
              .having(
                (e) => e.message,
                'message',
                contains('rejected the session it had just created'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('different instances'),
              ),
        ),
      );
      expect(client.trace, contains('session: received'));
    });

    test('a failing tools/list on a stale session reconnects once, then explains', () async {
      // The handshake works; afterwards every request on the session is unknown.
      var initializes = 0;
      final client = McpClient(
        _config('https://cf.test/mcp', transport: McpTransport.streamableHttp),
        httpClient: MockClient((request) async {
          if (request.body.contains('"initialize"')) {
            initializes++;
            final id = (jsonDecode(request.body) as Map)['id'];
            return http.Response(
              '{"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"x","version":"1"}}}',
              200,
              headers: {
                'content-type': 'application/json',
                'mcp-session-id': 's$initializes',
              },
            );
          }
          if (request.body.contains('notifications/initialized')) {
            return http.Response('', 202);
          }
          return http.Response(sessionGoneBody, 404);
        }),
      );
      await client.connect();
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            contains('rejected the session'),
          ),
        ),
      );
      expect(
        initializes,
        2,
        reason: 'one new session was tried, as the spec says',
      );
      expect(
        client.trace,
        contains('session unknown to the server: starting a new one'),
      );
    });

    test('a notification refused with a plain 400 is tolerated', () async {
      final server = SessionTroubleServer(badNotification: true, tools: _tools);
      final client = McpClient(
        _config('https://cf.test/mcp', transport: McpTransport.streamableHttp),
        httpClient: server.client,
      );
      await client.connect();
      expect((await client.listTools()).single.name, 'search_docs');
    });

    test('a 404 on initialize itself is not blamed on sessions', () async {
      final client = McpClient(
        _config('https://cf.test/mcp', transport: McpTransport.streamableHttp),
        httpClient: MockClient((_) async => http.Response('nope', 404)),
      );
      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            startsWith('HTTP 404'),
          ),
        ),
      );
    });
  });

  group('auto-detection works around it', () {
    final sseServer = FakeSseServer(
      tools: _tools,
      handlers: {'search_docs': (_) => textResult('docs result')},
    );

    test(
      '/mcp that cannot keep sessions falls back to the sibling /sse',
      () async {
        final server = SessionTroubleServer(
          hideSessionHeader: true,
          sse: sseServer,
        );
        final c = await makeContainer(httpClient: server.client);
        addTearDown(c.dispose);

        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Cloudflare', url: 'https://cf.test/mcp');

        expect(runtime.status, ServerStatus.connected);
        expect(runtime.tools.map((t) => t.name), ['search_docs']);
        expect(runtime.config.transport, McpTransport.sse);
        expect(
          runtime.config.url,
          'https://cf.test/sse',
          reason: 'the working endpoint is remembered',
        );
        expect(
          runtime.trace.any(
            (l) => l.contains('Streamable HTTP at https://cf.test/mcp'),
          ),
          isTrue,
        );
        expect(
          runtime.trace.any(
            (l) => l.contains('Legacy SSE at https://cf.test/sse'),
          ),
          isTrue,
        );
        expect(
          runtime.trace.any(
            (l) => l.contains('Session expired or does not exist'),
          ),
          isTrue,
          reason: 'what went wrong on the first try is kept in the trace',
        );
      },
    );

    test(
      'the same applies when the session is rejected rather than hidden',
      () async {
        final server = SessionTroubleServer(
          rejectSession: true,
          sse: sseServer,
        );
        final c = await makeContainer(httpClient: server.client);
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Cloudflare', url: 'https://cf.test/mcp');
        expect(runtime.status, ServerStatus.connected);
        expect(runtime.config.transport, McpTransport.sse);
      },
    );

    test('a transport must list tools too, not just initialize', () async {
      // Initialize works, tools/list is refused (404) → the next candidate wins.
      var firstListAttempted = false;
      final sse = FakeSseServer(tools: _tools);
      final client = MockClient.streaming((request, bodyStream) async {
        if (request.url.path == '/sse' ||
            request.url.path.startsWith('/messages')) {
          return forwardTo(sse.client, request, bodyStream);
        }
        final body = await bodyStream.bytesToString();
        http.StreamedResponse reply(
          int s,
          String b, [
          Map<String, String>? h,
        ]) => http.StreamedResponse(
          Stream.value(b.codeUnits),
          s,
          headers: {'content-type': 'application/json', ...?h},
        );
        if (body.contains('"initialize"')) {
          final id = (jsonDecode(body) as Map)['id'];
          return reply(
            200,
            '{"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"x","version":"1"}}}',
          );
        }
        if (body.contains('tools/list')) {
          firstListAttempted = true;
          return reply(404, 'not found');
        }
        return reply(202, '');
      });

      final connection = AutoMcpConnection(
        _config('https://cf.test/mcp'),
        httpClient: client,
      );
      final info = await connection.connect();
      expect(firstListAttempted, isTrue);
      expect(connection.transport, McpTransport.sse);
      expect(connection.endpointUrl, 'https://cf.test/sse');
      expect(info.name, 'vscode-mcp-bridge');
      expect((await connection.listTools()).single.name, 'search_docs');
    });

    test('when every transport fails, the message says why for each', () async {
      final server = SessionTroubleServer(hideSessionHeader: true);
      final c = await makeContainer(httpClient: server.client);
      addTearDown(c.dispose);
      final runtime = await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Cloudflare', url: 'https://cf.test/mcp');

      expect(runtime.status, ServerStatus.error);
      expect(runtime.error, contains('No MCP transport worked'));
      expect(runtime.error, contains('Streamable HTTP at https://cf.test/mcp'));
      expect(runtime.error, contains('could not read the Mcp-Session-Id'));
      expect(runtime.error, contains('Legacy SSE at https://cf.test/sse'));
      expect(
        runtime.trace,
        isNotEmpty,
        reason: 'there is a trace to look at under Connection details',
      );
    });

    test(
      'healthy Streamable HTTP servers are unaffected and keep their transport',
      () async {
        final server = FakeMcpServer(tools: _tools);
        final c = await makeContainer(server: server);
        addTearDown(c.dispose);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(name: 'Modern', url: 'https://mcp.test/mcp');
        expect(runtime.status, ServerStatus.connected);
        expect(runtime.config.transport, McpTransport.streamableHttp);
        expect(runtime.config.url, 'https://mcp.test/mcp');
        expect(
          runtime.trace,
          containsAllInOrder(['POST initialize → 200', 'session: received']),
        );
        expect(
          runtime.trace.where((l) => l.contains('tools/list')),
          isNotEmpty,
        );
      },
    );
  });

  group('candidates', () {
    String show(String url) =>
        connectionCandidates(_config(url))
            .map((a) => '${a.transport.wire} ${a.url}')
            .join(' | ');

    test('a /mcp URL also tries the sibling /sse', () {
      expect(
        show('https://cf.test/mcp'),
        'streamable-http https://cf.test/mcp | sse https://cf.test/mcp | sse https://cf.test/sse',
      );
    });

    test('siblings keep the rest of the path', () {
      expect(
        show('https://h.test/api/v2/mcp'),
        contains('sse https://h.test/api/v2/sse'),
      );
      expect(
        show('https://h.test/api/v2/sse'),
        contains('streamable-http https://h.test/api/v2/mcp'),
      );
    });
  });
}
