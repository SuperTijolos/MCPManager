import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef ToolHandler = Map<String, dynamic> Function(Map<String, dynamic> args);

/// A small MCP server (Streamable HTTP, JSON replies) the tests put behind a
/// portal.
class FakeUpstream {
  FakeUpstream._(this._server, this.tools, this.handlers, this.requireToken);

  final HttpServer _server;
  final List<Map<String, dynamic>> tools;
  final Map<String, ToolHandler> handlers;

  /// When set, every request must carry `Authorization: Bearer <token>`.
  String? requireToken;

  /// Every JSON-RPC body received, in order.
  final requests = <Map<String, dynamic>>[];

  /// Headers of every request, in order.
  final headers = <Map<String, String>>[];

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port/mcp';

  static Future<FakeUpstream> start({
    List<Map<String, dynamic>> tools = const [],
    Map<String, ToolHandler> handlers = const {},
    String? requireToken,
    int port = 0,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final upstream = FakeUpstream._(
      server,
      [...tools],
      {...handlers},
      requireToken,
    );
    server.listen(upstream._handle);
    return upstream;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final h = <String, String>{};
    request.headers.forEach((name, values) => h[name] = values.join(','));
    headers.add(h);

    if (requireToken != null &&
        request.headers.value('authorization') != 'Bearer $requireToken') {
      request.response
        ..statusCode = 401
        ..write('{"error":"unauthorized"}');
      await request.response.close();
      return;
    }
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    final message = (jsonDecode(body) as Map).cast<String, dynamic>();
    requests.add(message);
    final id = message['id'];
    if (id == null) {
      request.response.statusCode = 202;
      await request.response.close();
      return;
    }
    Map<String, dynamic> result;
    switch (message['method']) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake-upstream', 'version': '9.9.9'},
        };
      case 'tools/list':
        result = {'tools': tools};
      case 'tools/call':
        final params = (message['params'] as Map).cast<String, dynamic>();
        final handler = handlers[params['name']];
        if (handler == null) {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'error': {'code': -32602, 'message': 'Unknown tool'},
              }),
            );
          await request.response.close();
          return;
        }
        result = handler(
          ((params['arguments'] as Map?) ?? const {}).cast<String, dynamic>(),
        );
      case 'ping':
        result = {};
      default:
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32601, 'message': 'Method not found'},
            }),
          );
        await request.response.close();
        return;
    }
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    await request.response.close();
  }
}

Map<String, dynamic> textResult(String text, {bool isError = false}) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
  if (isError) 'isError': true,
};

Map<String, dynamic> tool(
  String name, {
  String description = '',
  Map<String, dynamic> properties = const {},
  List<String> required = const [],
  Map<String, dynamic>? annotations,
}) => {
  'name': name,
  'description': description.isEmpty ? 'Does $name.' : description,
  'inputSchema': {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
  },
  'annotations': ?annotations,
};
