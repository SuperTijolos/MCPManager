import 'provider_config.dart';

/// A starting point when adding a model provider.
class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.kind,
    this.name = '',
    this.baseUrl = '',
    this.urlHint,
    this.models = const [],
    this.needsKey = false,
  });

  final String id;
  final String label;
  final String description;
  final ProviderKind kind;

  /// Suggested display name.
  final String name;

  /// Prefilled endpoint; empty when the user has to supply it.
  final String baseUrl;
  final String? urlHint;
  final List<String> models;

  /// Hosted services that need an API key.
  final bool needsKey;
}

const providerPresets = [
  ProviderPreset(
    id: 'ollama-local',
    label: 'Ollama on this computer',
    description: 'Runs Gemma 4 and other models locally.',
    kind: ProviderKind.ollama,
    name: 'Ollama (local)',
    baseUrl: 'http://localhost:11434',
    models: ['gemma4'],
  ),
  ProviderPreset(
    id: 'ollama-remote',
    label: 'Ollama on another machine',
    description: 'A server on your network or tailnet.',
    kind: ProviderKind.ollama,
    name: 'Ollama (remote)',
    urlHint: 'http://100.x.y.z:11434',
    models: ['gemma4'],
  ),
  ProviderPreset(
    id: 'ollama-cloud',
    label: 'Ollama Cloud',
    description: 'Hosted models; needs an Ollama API key.',
    kind: ProviderKind.ollama,
    name: 'Ollama Cloud',
    baseUrl: 'https://ollama.com',
    needsKey: true,
  ),
  ProviderPreset(
    id: 'lm-studio',
    label: 'LM Studio',
    description: 'Its local server speaks the OpenAI API.',
    kind: ProviderKind.openaiCompatible,
    name: 'LM Studio',
    baseUrl: 'http://localhost:1234/v1',
  ),
  ProviderPreset(
    id: 'openrouter',
    label: 'OpenRouter',
    description: 'Many hosted models behind one key.',
    kind: ProviderKind.openaiCompatible,
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    needsKey: true,
  ),
  ProviderPreset(
    id: 'openai',
    label: 'OpenAI',
    description: 'api.openai.com; needs an API key.',
    kind: ProviderKind.openaiCompatible,
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    needsKey: true,
  ),
  ProviderPreset(
    id: 'custom',
    label: 'Other OpenAI-compatible endpoint',
    description: 'vLLM, llama.cpp server, a gateway… anything with /v1.',
    kind: ProviderKind.openaiCompatible,
    name: 'Custom endpoint',
    urlHint: 'https://host/v1',
  ),
];
