import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_dart/ollama_dart.dart' show RetryPolicy;
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/llm/ollama_provider.dart';
import 'package:mcp_manager/engine/llm/openai_provider.dart';
import 'package:mcp_manager/engine/llm/provider_config.dart';

const _ollama = ProviderConfig(
  id: 'o',
  name: 'Ollama',
  kind: ProviderKind.ollama,
  baseUrl: 'http://ollama.test:11434',
);
const _openai = ProviderConfig(
  id: 'x',
  name: 'Compat',
  kind: ProviderKind.openaiCompatible,
  baseUrl: 'https://llm.test/v1',
  apiKey: 'sk-test',
);

const _weatherTool = LlmToolSpec(
  name: 'weather__forecast',
  description: 'Get a forecast',
  parameters: {
    'type': 'object',
    'properties': {
      'city': {'type': 'string'},
    },
  },
);

String _ndjson(List<Map<String, dynamic>> lines) =>
    '${lines.map(jsonEncode).join('\n')}\n';

void main() {
  group('OllamaLlmProvider', () {
    test(
      'streams text, thinking, tool calls and usage; sends tools and history',
      () async {
        late Map<String, dynamic> sent;
        final provider = OllamaLlmProvider(
          _ollama,
          httpClient: MockClient.streaming((request, bodyStream) async {
            sent = jsonDecode(
              await bodyStream.bytesToString(),
            ) as Map<String, dynamic>;
            final body = _ndjson([
              {
                'model': 'gemma4',
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'thinking': 'hmm',
                },
                'done': false,
              },
              {
                'model': 'gemma4',
                'message': {'role': 'assistant', 'content': 'Checking'},
                'done': false,
              },
              {
                'model': 'gemma4',
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': [
                    {
                      'function': {
                        'name': 'weather__forecast',
                        'arguments': {'city': 'Portimão'},
                      },
                    },
                  ],
                },
                'done': false,
              },
              {
                'model': 'gemma4',
                'message': {'role': 'assistant', 'content': ''},
                'done': true,
                'prompt_eval_count': 12,
                'eval_count': 7,
              },
            ]);
            return http.StreamedResponse(
              Stream.value(utf8.encode(body)),
              200,
              headers: {'content-type': 'application/x-ndjson'},
            );
          }),
        );

        final events = await provider
            .chat(
              model: 'gemma4',
              messages: const [
                LlmMessage.system('sys'),
                LlmMessage.user('weather?'),
                LlmMessage.assistant(
                  '',
                  toolCalls: [
                    LlmToolCall(
                      id: 'c1',
                      name: 'weather__forecast',
                      arguments: {'city': 'Faro'},
                    ),
                  ],
                ),
                LlmMessage.tool(
                  'sunny',
                  toolCallId: 'c1',
                  toolName: 'weather__forecast',
                ),
              ],
              tools: const [_weatherTool],
            )
            .toList();

        expect(events.whereType<LlmThinkingDelta>().single.text, 'hmm');
        expect(events.whereType<LlmTextDelta>().single.text, 'Checking');
        final calls = events.whereType<LlmToolCallsEvent>().single.calls;
        expect(calls.single.name, 'weather__forecast');
        expect(calls.single.arguments, {'city': 'Portimão'});
        expect(calls.single.id, isNotEmpty);
        final done = events.whereType<LlmDone>().single;
        expect((done.promptTokens, done.completionTokens), (12, 7));

        expect(sent['model'], 'gemma4');
        final tools = sent['tools'] as List;
        expect((tools.single as Map)['function']['name'], 'weather__forecast');
        final messages = (sent['messages'] as List).cast<Map>();
        expect(messages.map((m) => m['role']), [
          'system',
          'user',
          'assistant',
          'tool',
        ]);
        expect(messages[2]['tool_calls'], isNotEmpty);
        expect(messages[3]['tool_name'], 'weather__forecast');
      },
    );

    test('listModels reports tool capability', () async {
      final provider = OllamaLlmProvider(
        _ollama,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/tags');
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'name': 'gemma4:latest',
                  'model': 'gemma4:latest',
                  'capabilities': ['completion', 'tools'],
                },
                {
                  'name': 'tiny:1b',
                  'model': 'tiny:1b',
                  'capabilities': ['completion'],
                },
                {'name': 'old:7b', 'model': 'old:7b'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final models = await provider.listModels();
      expect(models.map((m) => (m.name, m.supportsTools)), [
        ('gemma4:latest', true),
        ('tiny:1b', false),
        ('old:7b', null),
      ]);
    });

    test('connection errors become LlmException', () async {
      final provider = OllamaLlmProvider(
        _ollama,
        httpClient: MockClient(
          (_) async => throw http.ClientException('refused'),
        ),
        retryPolicy: const RetryPolicy(maxRetries: 0),
      );
      expect(provider.listModels(), throwsA(isA<LlmException>()));
    });
  });

  group('OpenAiLlmProvider', () {
    test(
      'streams deltas and assembles tool calls split across chunks',
      () async {
        late http.BaseRequest seen;
        late Map<String, dynamic> sent;
        final provider = OpenAiLlmProvider(
          _openai,
          httpClient: MockClient.streaming((request, bodyStream) async {
            seen = request;
            sent = jsonDecode(
              await bodyStream.bytesToString(),
            ) as Map<String, dynamic>;
            String sse(Map<String, dynamic> data) =>
                'data: ${jsonEncode(data)}\n\n';
            final body = [
              sse({
                'choices': [
                  {
                    'delta': {'role': 'assistant', 'content': 'Hel'},
                  },
                ],
              }),
              sse({
                'choices': [
                  {
                    'delta': {'content': 'lo'},
                  },
                ],
              }),
              sse({
                'choices': [
                  {
                    'delta': {'reasoning_content': 'because'},
                  },
                ],
              }),
              sse({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_9',
                          'function': {
                            'name': 'weather__forecast',
                            'arguments': '{"ci',
                          },
                        },
                      ],
                    },
                  },
                ],
              }),
              sse({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'function': {'arguments': 'ty":"Faro"}'},
                        },
                      ],
                    },
                  },
                ],
              }),
              sse({
                'choices': [],
                'usage': {'prompt_tokens': 5, 'completion_tokens': 3},
              }),
              'data: [DONE]\n\n',
            ].join();
            return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
          }),
        );

        final events = await provider
            .chat(
              model: 'm',
              messages: const [
                LlmMessage.user('hi'),
                LlmMessage.assistant(
                  '',
                  toolCalls: [
                    LlmToolCall(
                      id: 'c0',
                      name: 'weather__forecast',
                      arguments: {'city': 'X'},
                    ),
                  ],
                ),
                LlmMessage.tool(
                  'ok',
                  toolCallId: 'c0',
                  toolName: 'weather__forecast',
                ),
              ],
              tools: const [_weatherTool],
            )
            .toList();

        expect(
          events.whereType<LlmTextDelta>().map((e) => e.text).join(),
          'Hello',
        );
        expect(events.whereType<LlmThinkingDelta>().single.text, 'because');
        final call = events.whereType<LlmToolCallsEvent>().single.calls.single;
        expect((call.id, call.name), ('call_9', 'weather__forecast'));
        expect(call.arguments, {'city': 'Faro'});
        final done = events.whereType<LlmDone>().single;
        expect((done.promptTokens, done.completionTokens), (5, 3));

        expect(seen.url.toString(), 'https://llm.test/v1/chat/completions');
        expect(seen.headers['authorization'], 'Bearer sk-test');
        expect(sent['stream'], true);
        final messages = (sent['messages'] as List).cast<Map>();
        expect(
          messages[1]['tool_calls'][0]['function']['arguments'],
          '{"city":"X"}',
        );
        expect(messages[2], {
          'role': 'tool',
          'tool_call_id': 'c0',
          'content': 'ok',
        });
      },
    );

    test('HTTP errors carry the status', () async {
      final provider = OpenAiLlmProvider(
        _openai,
        httpClient: MockClient.streaming((_, _) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"error":"bad key"}')),
            401,
          );
        }),
      );
      expect(
        provider
            .chat(model: 'm', messages: const [LlmMessage.user('x')])
            .toList(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('401'),
          ),
        ),
      );
    });

    test('listModels reads data[].id', () async {
      final provider = OpenAiLlmProvider(
        _openai,
        httpClient: MockClient((request) async {
          expect(request.url.toString(), 'https://llm.test/v1/models');
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'a'},
                {'id': 'b'},
              ],
            }),
            200,
          );
        }),
      );
      expect((await provider.listModels()).map((m) => m.name), ['a', 'b']);
    });
  });
}
