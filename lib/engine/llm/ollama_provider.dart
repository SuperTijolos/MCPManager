import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as o;

import '../core/ids.dart';
import 'llm_types.dart';
import 'provider_config.dart';

/// Talks to an Ollama server (local, remote, or Ollama Cloud). Gemma 4 runs
/// through here: `ollama pull gemma4` and pick it in Settings.
class OllamaLlmProvider implements LlmProvider {
  OllamaLlmProvider(
    ProviderConfig config, {
    http.Client? httpClient,
    // Short on purpose: an unreachable server should fail in ~1.5s, not ~7s.
    o.RetryPolicy retryPolicy = const o.RetryPolicy(
      maxRetries: 2,
      initialDelay: Duration(milliseconds: 500),
    ),
  }) : _numCtx = config.contextLength ?? defaultOllamaContext,
       _client = o.OllamaClient(
         httpClient: httpClient,
         config: o.OllamaConfig(
           baseUrl: config.baseUrl,
           timeout: const Duration(minutes: 5),
           retryPolicy: retryPolicy,
           authProvider: (config.apiKey ?? '').isEmpty
               ? null
               : o.BearerTokenProvider(config.apiKey!),
         ),
       );

  final o.OllamaClient _client;
  final int _numCtx;

  @override
  Future<List<LlmModel>> listModels() async {
    try {
      final response = await _client.models.list();
      return [
        for (final m in response.models ?? const <o.ModelSummary>[])
          if ((m.name ?? m.model) != null)
            LlmModel(
              (m.name ?? m.model)!,
              supportsTools: m.capabilities?.contains('tools'),
            ),
      ];
    } catch (e) {
      throw LlmException(_describe(e));
    }
  }

  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) async* {
    final request = o.ChatRequest(
      model: model,
      messages: [for (final m in messages) _toOllama(m)],
      options: o.ModelOptions(numCtx: _numCtx),
      tools: tools.isEmpty
          ? null
          : [
              for (final t in tools)
                o.ToolDefinition(
                  function: o.ToolFunction(
                    name: t.name,
                    description: t.description,
                    parameters: t.parameters,
                  ),
                ),
            ],
    );

    final calls = <LlmToolCall>[];
    int? promptTokens;
    int? completionTokens;
    try {
      await for (final event in _client.chat.createStream(request: request)) {
        final message = event.message;
        final thinking = message?.thinking;
        if (thinking != null && thinking.isNotEmpty) {
          yield LlmThinkingDelta(thinking);
        }
        final content = message?.content;
        if (content != null && content.isNotEmpty) yield LlmTextDelta(content);
        for (final call in message?.toolCalls ?? const <o.ToolCall>[]) {
          final fn = call.function;
          if (fn == null) continue;
          calls.add(
            LlmToolCall(
              id: call.id ?? newId('call'),
              name: fn.name,
              arguments: fn.arguments ?? const {},
            ),
          );
        }
        if (event.done == true) {
          promptTokens = event.promptEvalCount;
          completionTokens = event.evalCount;
        }
      }
    } catch (e) {
      throw LlmException(_describe(e));
    }
    if (calls.isNotEmpty) yield LlmToolCallsEvent(calls);
    yield LlmDone(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  o.ChatMessage _toOllama(LlmMessage m) => switch (m.role) {
    LlmRole.system => o.ChatMessage.system(m.content),
    LlmRole.user => o.ChatMessage.user(m.content),
    LlmRole.assistant => o.ChatMessage.assistant(
      m.content,
      thinking: m.thinking,
      toolCalls: m.toolCalls.isEmpty
          ? null
          : [
              for (final c in m.toolCalls)
                o.ToolCall(
                  id: c.id,
                  function: o.ToolCallFunction(
                    name: c.name,
                    arguments: c.arguments,
                  ),
                ),
            ],
    ),
    LlmRole.tool => o.ChatMessage.tool(
      m.content,
      toolName: m.toolName,
      toolCallId: m.toolCallId,
    ),
  };

  String _describe(Object e) {
    final text = '$e';
    if (text.contains('XMLHttpRequest') || text.contains('Failed to fetch')) {
      return 'Could not reach Ollama. In a browser, start Ollama with '
          'OLLAMA_ORIGINS="*" (or this app\'s origin) so CORS is allowed. '
          '($text)';
    }
    return text;
  }

  @override
  void close() => _client.close();
}
