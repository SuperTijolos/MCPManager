import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/mcp/mcp_client.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';

import '../support/fakes.dart';

const _config = McpServerConfig(
  id: 's1',
  name: 'fake',
  url: 'https://mcp.test/mcp',
  headers: {'Authorization': 'Bearer t0ken'},
);

Map<String, dynamic> _tool(String name, {Map<String, dynamic>? annotations}) =>
    {
      'name': name,
      'description': 'does $name',
      'inputSchema': {'type': 'object', 'properties': {}},
      'annotations': ?annotations,
    };

void main() {
  for (final sse in [false, true]) {
    group('Streamable HTTP (${sse ? 'SSE' : 'JSON'} replies)', () {
      test(
        'connect negotiates, stores the session and sends initialized',
        () async {
          final server = FakeMcpServer(sse: sse);
          final client = McpClient(_config, httpClient: server.client);
          final info = await client.connect();

          expect(info.name, 'fake');
          expect(info.version, '1.2.3');
          expect(info.protocolVersion, '2025-06-18');
          expect(client.isConnected, isTrue);
          expect(server.bodies.map((b) => b['method']), [
            'initialize',
            'notifications/initialized',
          ]);
          // Auth header comes from config; session id is sent after initialize.
          expect(
            server.requests.first.headers['Authorization'],
            'Bearer t0ken',
          );
          expect(
            server.requests.first.headers.containsKey('mcp-session-id'),
            isFalse,
          );
          expect(server.requests.last.headers['mcp-session-id'], 'sess-1');
          expect(
            server.requests.last.headers['mcp-protocol-version'],
            '2025-06-18',
          );
        },
      );

      test('listTools parses tools and annotations', () async {
        final server = FakeMcpServer(
          sse: sse,
          tools: [
            _tool('read', annotations: {'readOnlyHint': true}),
            _tool('write'),
          ],
        );
        final client = McpClient(_config, httpClient: server.client);
        await client.connect();
        final tools = await client.listTools();

        expect(tools.map((t) => t.name), ['read', 'write']);
        expect(tools[0].isReadOnly, isTrue);
        expect(tools[1].isReadOnly, isFalse);
        expect(tools[1].isDestructive, isTrue);
      });

      test('callTool returns text and error flag', () async {
        final server = FakeMcpServer(
          sse: sse,
          handlers: {
            'echo': (args) => textResult('echo: ${args['msg']}'),
            'boom': (_) => textResult('it broke', isError: true),
          },
        );
        final client = McpClient(_config, httpClient: server.client);
        await client.connect();

        final ok = await client.callTool('echo', {'msg': 'hi'});
        expect(ok.text, 'echo: hi');
        expect(ok.isError, isFalse);

        final bad = await client.callTool('boom', {});
        expect(bad.isError, isTrue);
        expect(bad.text, 'it broke');
      });
    });
  }

  test('JSON-RPC errors become McpException with code', () async {
    final server = FakeMcpServer();
    final client = McpClient(_config, httpClient: server.client);
    await client.connect();
    expect(
      () => client.callTool('missing', {}),
      throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
    );
  });

  test('a 404 on a stale session reconnects once and retries', () async {
    final server = FakeMcpServer(
      handlers: {'echo': (_) => textResult('again')},
    );
    final client = McpClient(_config, httpClient: server.client);
    await client.connect();
    server.expireSession = true;

    final result = await client.callTool('echo', {});
    expect(result.text, 'again');
    final initializes = server.bodies.where((b) => b['method'] == 'initialize');
    expect(initializes, hasLength(2));
  });

  test('401 is reported as unauthorized', () async {
    final client = McpClient(_config, httpClient: _statusClient(401));
    expect(
      () => client.connect(),
      throwsA(
        isA<McpException>().having(
          (e) => e.message,
          'message',
          contains('Unauthorized'),
        ),
      ),
    );
  });

  test('pagination follows nextCursor', () async {
    var page = 0;
    final cursors = <Object?>[];
    final client = McpClient(
      _config,
      httpClient: _scripted((method, params) {
        if (method == 'initialize') {
          return {
            'protocolVersion': '2025-06-18',
            'serverInfo': {'name': 'p', 'version': '1'},
          };
        }
        cursors.add(params?['cursor']);
        page++;
        return page == 1
            ? {
                'tools': [_tool('a')],
                'nextCursor': 'c2',
              }
            : {
                'tools': [_tool('b')],
              };
      }),
    );
    await client.connect();
    final tools = await client.listTools();
    expect(tools.map((t) => t.name), ['a', 'b']);
    expect(cursors, [null, 'c2']);
  });

  group('parseSseData', () {
    test('joins multi-line data and ignores comments', () {
      const body =
          ': ping\r\n\r\nevent: message\r\ndata: {"a":\r\ndata: 1}\r\n\r\ndata: {"b":2}\r\n';
      expect(parseSseData(body), ['{"a":\n1}', '{"b":2}']);
    });
  });

  group('McpToolResult.fromJson', () {
    test('renders mixed content', () {
      final r = McpToolResult.fromJson({
        'content': [
          {'type': 'text', 'text': 'hello'},
          {'type': 'image', 'mimeType': 'image/png', 'data': 'AAAA'},
          {
            'type': 'resource',
            'resource': {'uri': 'file:///x', 'text': 'body'},
          },
        ],
      });
      expect(r.text, 'hello\n[image: image/png]\nbody');
    });

    test('falls back to structuredContent', () {
      final r = McpToolResult.fromJson({
        'content': [],
        'structuredContent': {'n': 1},
      });
      expect(r.text, '{"n":1}');
    });
  });
}

http.Client _statusClient(int status) =>
    MockClient((_) async => http.Response('nope', status));

/// Answers every request with `{result: handler(method, params)}`.
http.Client _scripted(
  Map<String, dynamic> Function(String method, Map<String, dynamic>? params)
  handler,
) {
  return MockClient((request) async {
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    if (body['id'] == null) return http.Response('', 202);
    final result = handler(
      body['method'] as String,
      (body['params'] as Map?)?.cast<String, dynamic>(),
    );
    return http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}
