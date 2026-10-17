import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/core/json.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeMcpServer {
  FakeMcpServer({
    this.tools = const [],
    this.handlers = const {},
    this.sse = false,
    this.sessionId = 'sess-1',
  });

  final List<Json> tools;

  /// tool name -> handler returning the `result` payload of tools/call.
  final Map<String, Json Function(Json args)> handlers;
  final bool sse;
  final String? sessionId;

  final requests = <http.Request>[];
  final bodies = <Json>[];

  /// Set to make the next request with a session header fail with 404.
  bool expireSession = false;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    if (request.method == 'DELETE') return http.Response('', 200);
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    bodies.add(body);
    final method = body['method'] as String;
    final id = body['id'];

    if (method != 'initialize' &&
        expireSession &&
        request.headers.containsKey('mcp-session-id')) {
      expireSession = false;
      return http.Response('session not found', 404);
    }
    if (id == null) return http.Response('', 202);

    Json result;
    switch (method) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake', 'version': '1.2.3'},
        };
      case 'tools/list':
        result = {'tools': tools};
      case 'tools/call':
        final params = (body['params'] as Map).cast<String, dynamic>();
        final handler = handlers[params['name']];
        if (handler == null) {
          return _reply({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'Unknown tool'},
          });
        }
        result = handler(
          (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {},
        );
      case 'ping':
        result = {};
      default:
        return _reply({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
    }

    return _reply({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }, withSession: method == 'initialize');
  });

  http.Response _reply(Json message, {bool withSession = false}) {
    final headers = <String, String>{
      if (withSession && sessionId != null) 'mcp-session-id': sessionId!,
    };
    if (sse) {
      return http.Response(
        ': keep-alive\n\nevent: message\ndata: ${jsonEncode(message)}\n\n',
        200,
        headers: {...headers, 'content-type': 'text/event-stream'},
      );
    }
    return http.Response(
      jsonEncode(message),
      200,
      headers: {...headers, 'content-type': 'application/json'},
    );
  }
}

Json textResult(String text, {bool isError = false}) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
  if (isError) 'isError': true,
};

/// Scripted LLM: each call to [chat] consumes the next list of events.
class ScriptedLlm implements LlmProvider {
  ScriptedLlm(this.turns);

  final List<List<LlmEvent>> turns;
  final received = <List<LlmMessage>>[];
  final toolSpecs = <List<LlmToolSpec>>[];
  var _next = 0;
  bool closed = false;

  @override
  Future<List<LlmModel>> listModels() async => [
    const LlmModel('gemma4', supportsTools: true),
  ];

  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) async* {
    received.add(List.of(messages));
    toolSpecs.add(tools);
    final turn = _next < turns.length
        ? turns[_next]
        : const <LlmEvent>[LlmDone()];
    _next++;
    for (final e in turn) {
      yield e;
    }
  }

  @override
  void close() => closed = true;
}

Future<ProviderContainer> makeContainer({
  FakeMcpServer? server,
  LlmProvider? llm,
  http.Client? httpClient,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      if (server != null || httpClient != null)
        mcpHttpClientFactoryProvider.overrideWithValue(
          () => httpClient ?? server!.client,
        ),
      if (llm != null) llmProviderFactoryProvider.overrideWithValue((_) => llm),
    ],
  );
  return container;
}
