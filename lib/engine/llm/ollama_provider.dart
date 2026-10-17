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
           authProvider: config.bearerKey.isEmpty
               ? null
               : o.BearerTokenProvider(config.bearerKey),
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

    // Some thinking-capable Ollama models end a stream with only reasoning:
    // no content and no tool calls. That is not a usable Operator reply.
    // Repeat the same request once, disabling thinking for the retry. Do not
    // add a synthetic message or change the user's chat history.
    for (var attempt = 0; attempt < 2; attempt++) {
      var hasContent = false;
      var hasThinking = false;
      try {
        await for (final event in _client.chat.createStream(
          request: attempt == 0
              ? request
              : request.copyWith(think: const o.ThinkValue.enabled(false)),
        )) {
          final message = event.message;
          final thinking = message?.thinking;
          if (thinking != null && thinking.isNotEmpty) {
            hasThinking = true;
            // Retain the first attempt's thinking as diagnostic context.
            // A retry with thinking disabled normally does not emit more.
            yield LlmThinkingDelta(thinking);
          }
          final content = message?.content;
          if (content != null && content.isNotEmpty) {
            // Whitespace-only chunks are not a visible final answer.
            if (content.trim().isNotEmpty) hasContent = true;
            yield LlmTextDelta(content);
          }
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

      if (hasContent || calls.isNotEmpty) {
        if (calls.isNotEmpty) yield LlmToolCallsEvent(calls);
        yield LlmDone(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
        );
        return;
      }

      // Only a reasoning-only reply gets an automatic retry. An entirely empty
      // reply, or a failed second attempt, becomes an actionable error rather
      // than silently ending the conversation.
      if (!hasThinking || attempt == 1) {
        throw LlmException(
          'Ollama returned no answer or tool call for "$model". '
          'Try again, increase the model context window, or choose another model.',
        );
      }
    }
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
