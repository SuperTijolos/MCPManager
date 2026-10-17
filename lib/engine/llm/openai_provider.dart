import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'llm_types.dart';
import 'provider_config.dart';

/// Any server that speaks the OpenAI chat-completions API: vLLM, LM Studio,
/// llama.cpp server, OpenRouter, Ollama's `/v1`, and so on.
class OpenAiLlmProvider implements LlmProvider {
  OpenAiLlmProvider(this.config, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final ProviderConfig config;
  final http.Client _http;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    if (config.bearerKey.isNotEmpty)
      'authorization': 'Bearer ${config.bearerKey}',
  };

  bool get _isOpenRouter =>
      Uri.tryParse(config.baseUrl)?.host.toLowerCase() == 'openrouter.ai';

  /// OpenRouter exposes `/models` without authentication, so a successful
  /// model listing by itself does not confirm that the configured key works.
  Future<void> _checkOpenRouterKey() async {
    if (!_isOpenRouter) return;
    final problem = openRouterKeyProblem(config.apiKey);
    if (problem != null) throw LlmException(problem);
    final http.Response response;
    try {
      response = await _http
          .get(Uri.parse('${config.baseUrl}/key'), headers: _headers)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw LlmException(_describe(e));
    }
    if (response.statusCode != 200) {
      throw LlmException(_httpError(response.statusCode, response.body));
    }
  }

  String _httpError(int status, String body) {
    final details = truncate(body, 300);
    if (status == 401) {
      return config.bearerKey.isEmpty
          ? 'HTTP 401: No API key is configured for ${config.baseUrl}. $details'
          : 'HTTP 401: Authentication rejected by ${config.baseUrl}. '
                'The app built an Authorization: Bearer header, but the '
                'response does not prove whether it reached the server. '
                'Check your API key, or inspect the browser Network request '
                '(do not share the header value). $details';
    }
    return 'HTTP $status: $details';
  }

  @override
  Future<List<LlmModel>> listModels() async {
    await _checkOpenRouterKey();
    final http.Response response;
    try {
      response = await _http
          .get(Uri.parse('${config.baseUrl}/models'), headers: _headers)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw LlmException(_describe(e));
    }
    if (response.statusCode != 200) {
      throw LlmException(_httpError(response.statusCode, response.body));
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map ? decoded['data'] : null;
    return [
      for (final m in (data as List?) ?? const [])
        if (m is Map && m['id'] != null) LlmModel('${m['id']}'),
    ];
  }

  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) async* {
    if (_isOpenRouter) {
      final problem = openRouterKeyProblem(config.apiKey);
      if (problem != null) throw LlmException(problem);
    }
    final request =
        http.Request('POST', Uri.parse('${config.baseUrl}/chat/completions'))
          ..headers.addAll({..._headers, 'accept': 'text/event-stream'})
          ..body = jsonEncode({
            'model': model,
            'stream': true,
            'stream_options': {'include_usage': true},
            'messages': [for (final m in messages) _toWire(m)],
            if (tools.isNotEmpty)
              'tools': [
                for (final t in tools)
                  {
                    'type': 'function',
                    'function': {
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.parameters,
                    },
                  },
              ],
          });

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (e) {
      throw LlmException(_describe(e));
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(_httpError(response.statusCode, body));
    }

    final partial = <int, _PartialCall>{};
    int? promptTokens;
    int? completionTokens;
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      final Json chunk;
      try {
        chunk = (jsonDecode(payload) as Map).cast<String, dynamic>();
      } catch (_) {
        continue;
      }
      final usage = chunk['usage'];
      if (usage is Map) {
        promptTokens = usage['prompt_tokens'] as int?;
        completionTokens = usage['completion_tokens'] as int?;
      }
      final choices = chunk['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final delta = (choices.first as Map)['delta'];
      if (delta is! Map) continue;

      final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
      if (reasoning is String && reasoning.isNotEmpty) {
        yield LlmThinkingDelta(reasoning);
      }
      final content = delta['content'];
      if (content is String && content.isNotEmpty) yield LlmTextDelta(content);

      for (final raw in (delta['tool_calls'] as List?) ?? const []) {
        if (raw is! Map) continue;
        final call = partial.putIfAbsent(
          raw['index'] as int? ?? partial.length,
          _PartialCall.new,
        );
        if (raw['id'] != null) call.id = '${raw['id']}';
        final fn = raw['function'];
        if (fn is Map) {
          if (fn['name'] != null) call.name += '${fn['name']}';
          if (fn['arguments'] != null) call.arguments.write(fn['arguments']);
        }
      }
    }

    if (partial.isNotEmpty) {
      final keys = partial.keys.toList()..sort();
      yield LlmToolCallsEvent([
        for (final k in keys)
          if (partial[k]!.name.isNotEmpty) partial[k]!.build(k),
      ]);
    }
    yield LlmDone(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  Json _toWire(LlmMessage m) => switch (m.role) {
    LlmRole.system => {'role': 'system', 'content': m.content},
    LlmRole.user => {'role': 'user', 'content': m.content},
    LlmRole.assistant => {
      'role': 'assistant',
      'content': m.content,
      if (m.toolCalls.isNotEmpty)
        'tool_calls': [
          for (final c in m.toolCalls)
            {
              'id': c.id,
              'type': 'function',
              'function': {
                'name': c.name,
                'arguments': jsonEncode(c.arguments),
              },
            },
        ],
    },
    LlmRole.tool => {
      'role': 'tool',
      'tool_call_id': m.toolCallId,
      'content': m.content,
    },
  };

  String _describe(Object e) {
    final text = '$e';
    if (text.contains('XMLHttpRequest') || text.contains('Failed to fetch')) {
      return 'Could not reach ${config.baseUrl}. In a browser the endpoint '
          'must allow CORS for this origin. ($text)';
    }
    return text;
  }

  @override
  void close() => _http.close();
}

class _PartialCall {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  LlmToolCall build(int index) {
    final raw = arguments.toString();
    return LlmToolCall(
      id: id.isEmpty ? 'call_$index' : id,
      name: name,
      arguments: raw.isEmpty ? const {} : (tryDecodeObject(raw) ?? const {}),
    );
  }
}
