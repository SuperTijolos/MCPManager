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

// Built in memory so GitHub does not mistake a test fixture for a real key.
final _openRouterSyntheticKey =
    'sk-or-v1-${List.filled(4, '0123456789abcdef').join()}';

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
        expect(
          (sent['options'] as Map)['num_ctx'],
          defaultOllamaContext,
          reason: "an unset context window must not fall back to Ollama's small default",
        );
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

    test(
      'retries a thinking-only Ollama reply once without thinking',
      () async {
        final sent = <Map<String, dynamic>>[];
        final provider = OllamaLlmProvider(
          _ollama,
          httpClient: MockClient.streaming((request, bodyStream) async {
            final payload = (jsonDecode(
              await bodyStream.bytesToString(),
            ) as Map).cast<String, dynamic>();
            sent.add(payload);
            final response = sent.length == 1
                ? _ndjson([
                    {
                      'model': 'qwen3.5:4b',
                      'message': {
                        'role': 'assistant',
                        'thinking': 'Let me check',
                      },
                      'done': false,
                    },
                    {
                      'model': 'qwen3.5:4b',
                      'message': {'role': 'assistant', 'content': ''},
                      'done': true,
                      'done_reason': 'stop',
                    },
                  ])
                : _ndjson([
                    {
                      'model': 'qwen3.5:4b',
                      'message': {
                        'role': 'assistant',
                        'content': 'Here are the tools.',
                      },
                      'done': true,
                      'done_reason': 'stop',
                      'eval_count': 7,
                    },
                  ]);
            return http.StreamedResponse(
              Stream.value(utf8.encode(response)),
              200,
              headers: {'content-type': 'application/x-ndjson'},
            );
          }),
        );
        addTearDown(provider.close);

        final events = await provider
            .chat(
              model: 'qwen3.5:4b',
              messages: const [LlmMessage.user('list the available tools')],
              tools: const [_weatherTool],
            )
            .toList();

        expect(sent, hasLength(2));
        expect(sent.first.containsKey('think'), isFalse);
        expect(sent.last['think'], isFalse);
        expect(
          sent.last['messages'],
          sent.first['messages'],
          reason: 'retry the identical user request, not fake another turn',
        );
        expect(sent.last['tools'], sent.first['tools']);
        expect(
          events.whereType<LlmThinkingDelta>().single.text,
          'Let me check',
        );
        expect(
          events.whereType<LlmTextDelta>().single.text,
          'Here are the tools.',
        );
        expect(events.whereType<LlmDone>(), hasLength(1));
      },
    );

    test('thinking-only retry with no answer raises a visible error', () async {
      var attempts = 0;
      final provider = OllamaLlmProvider(
        _ollama,
        httpClient: MockClient.streaming((request, bodyStream) async {
          attempts++;
          final body = _ndjson([
            {
              'model': 'qwen3.5:4b',
              'message': {
                'role': 'assistant',
                'thinking': 'Still considering this',
              },
              'done': true,
              'done_reason': 'stop',
            },
          ]);
          return http.StreamedResponse(
            Stream.value(utf8.encode(body)),
            200,
            headers: {'content-type': 'application/x-ndjson'},
          );
        }),
      );
      addTearDown(provider.close);

      await expectLater(
        provider.chat(
          model: 'qwen3.5:4b',
          messages: const [LlmMessage.user('what tools exist?')],
        ),
        emitsInOrder([
          isA<LlmThinkingDelta>(),
          isA<LlmThinkingDelta>(),
          emitsError(
            isA<LlmException>().having(
              (error) => error.message,
              'message',
              contains('no answer or tool call'),
            ),
          ),
        ]),
      );
      expect(attempts, 2, reason: 'never spin on reasoning-only responses');
    });

    test(
      'entirely empty Ollama reply is reported, not retried forever',
      () async {
        var attempts = 0;
        final provider = OllamaLlmProvider(
          _ollama,
          httpClient: MockClient.streaming((request, bodyStream) async {
            attempts++;
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _ndjson([
                    {
                      'model': 'qwen3.5:4b',
                      'message': {'role': 'assistant', 'content': ''},
                      'done': true,
                    },
                  ]),
                ),
              ),
              200,
              headers: {'content-type': 'application/x-ndjson'},
            );
          }),
        );
        addTearDown(provider.close);
        await expectLater(
          provider.chat(
            model: 'qwen3.5:4b',
            messages: const [LlmMessage.user('hello')],
          ),
          emitsError(isA<LlmException>()),
        );
        expect(attempts, 1);
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

    test('normalizes an accidentally pasted Bearer prefix', () async {
      final provider = OpenAiLlmProvider(
        _openai.copyWith(apiKey: '  Bearer sk-test  '),
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer sk-test');
          return http.Response('{"data": []}', 200);
        }),
      );
      expect(await provider.listModels(), isEmpty);
    });

    test('normalizes quoted and repeated bearer prefixes', () {
      expect(
        normalizeApiKey(' "Bearer Bearer $_openRouterSyntheticKey" '),
        _openRouterSyntheticKey,
      );
      expect(
        normalizeApiKey("'Bearer $_openRouterSyntheticKey'"),
        _openRouterSyntheticKey,
      );
      expect(openRouterKeyProblem('Bearer $_openRouterSyntheticKey'), isNull);
      expect(
        openRouterKeyProblem('Bearer sk-test'),
        contains('OpenRouter keys start with'),
      );
      expect(openRouterKeyProblem('sk-or-v1-abcdef'), contains('64 lowercase'));
      expect(
        openRouterKeyProblem('sk-or-v1-${List.filled(63, 'a').join()}'),
        contains('64 lowercase'),
      );
      expect(
        openRouterKeyProblem('sk-or-v1-${List.filled(64, 'A').join()}'),
        contains('64 lowercase'),
      );
      expect(
        openRouterKeyProblem('sk-or-v1-ab c'),
        contains('Invalid OpenRouter API key format'),
      );
    });

    test(
      'OpenRouter rejects malformed keys locally before a network call',
      () async {
        final provider = OpenAiLlmProvider(
          _openai.copyWith(
            baseUrl: 'https://openrouter.ai/api/v1',
            apiKey: 'Bearer sk-test',
          ),
          httpClient: MockClient((request) async {
            fail('Invalid credentials must not reach the network');
          }),
        );
        await expectLater(
          provider.listModels(),
          throwsA(
            isA<LlmException>().having(
              (e) => e.message,
              'message',
              contains('not an OpenRouter API key'),
            ),
          ),
        );
      },
    );

    test(
      'OpenRouter validates the key before publicly accessible models',
      () async {
        final paths = <String>[];
        final provider = OpenAiLlmProvider(
          _openai.copyWith(
            baseUrl: 'https://openrouter.ai/api/v1',
            apiKey: _openRouterSyntheticKey,
          ),
          httpClient: MockClient((request) async {
            paths.add(request.url.path);
            expect(
              request.headers['authorization'],
              'Bearer $_openRouterSyntheticKey',
            );
            if (request.url.path.endsWith('/key')) {
              return http.Response('{"data": {"label": "test"}}', 200);
            }
            return http.Response('{"data": [{"id": "test-model"}]}', 200);
          }),
        );
        expect((await provider.listModels()).single.name, 'test-model');
        expect(paths, ['/api/v1/key', '/api/v1/models']);
      },
    );

    test('OpenRouter rejects an invalid key before discovering models', () async {
      final provider = OpenAiLlmProvider(
        _openai.copyWith(
          baseUrl: 'https://openrouter.ai/api/v1',
          apiKey: _openRouterSyntheticKey,
        ),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/key');
          return http.Response(
            '{"error":{"message":"Missing Authentication header","code":401}}',
            401,
          );
        }),
      );
      await expectLater(
        provider.listModels(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            allOf(contains('401'), contains('Authorization: Bearer')),
          ),
        ),
      );
    });

    test(
      'OpenRouter missing key fails before sending network requests',
      () async {
        final provider = OpenAiLlmProvider(
          _openai.copyWith(
            baseUrl: 'https://openrouter.ai/api/v1',
            clearApiKey: true,
          ),
          httpClient: MockClient((request) async {
            fail('No request should be sent without an OpenRouter key');
          }),
        );
        await expectLater(
          provider.listModels(),
          throwsA(
            isA<LlmException>().having(
              (e) => e.message,
              'message',
              contains('requires an API key'),
            ),
          ),
        );
      },
    );

    test(
      'OpenRouter chat without a key fails before making requests',
      () async {
        final provider = OpenAiLlmProvider(
          _openai.copyWith(
            baseUrl: 'https://openrouter.ai/api/v1',
            clearApiKey: true,
          ),
          httpClient: MockClient.streaming((request, bodyStream) async {
            fail('No request should be sent without an OpenRouter key');
          }),
        );
        await expectLater(
          provider
              .chat(model: 'm', messages: const [LlmMessage.user('hi')])
              .toList(),
          throwsA(
            isA<LlmException>().having(
              (e) => e.message,
              'message',
              contains('requires an API key'),
            ),
          ),
        );
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

  test('an explicit context window is sent to Ollama', () async {
    late Map<String, dynamic> sent;
    final provider = OllamaLlmProvider(
      _ollama.copyWith(contextLength: 8192),
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          await bodyStream.bytesToString(),
        ) as Map<String, dynamic>;
        final done = _ndjson([
          {
            'model': 'gemma4',
            'message': {'role': 'assistant', 'content': 'hello'},
            'done': true,
          },
        ]);
        return http.StreamedResponse(Stream.value(utf8.encode(done)), 200);
      }),
    );
    await provider
        .chat(model: 'gemma4', messages: const [LlmMessage.user('hi')])
        .toList();
    expect((sent['options'] as Map)['num_ctx'], 8192);
  });
}
