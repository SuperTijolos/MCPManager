import '../core/json.dart';

/// Accept a pasted raw key or `Bearer <key>` without sending `Bearer Bearer`.
/// Do not change case or internal characters of the actual credential.
String normalizeApiKey(String? value) {
  var key = (value ?? '').trim();
  if (key.toLowerCase().startsWith('bearer ')) {
    key = key.substring(7).trim();
  }
  return key;
}

/// Public cloud APIs require credentials even when `/models` is anonymous.
bool providerRequiresApiKey(ProviderKind kind, String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase();
  return host == 'api.openai.com' ||
      host == 'openrouter.ai' ||
      (kind == ProviderKind.ollama && host == 'ollama.com');
}

/// Ollama's own default window is too small for the Operator's tool list, so a
/// provider without an explicit setting asks for this much.
const defaultOllamaContext = 16384;

enum ProviderKind {
  ollama('Ollama'),
  openaiCompatible('OpenAI-compatible');

  const ProviderKind(this.label);
  final String label;
}

class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.apiKey,
    this.models = const [],
    this.contextLength,
  });

  final String id;
  final String name;
  final ProviderKind kind;

  /// Ollama: `http://host:11434`. OpenAI-compatible: `https://host/v1`.
  final String baseUrl;
  final String? apiKey;

  /// Clean up existing saved keys as well as newly entered ones.
  String get bearerKey => normalizeApiKey(apiKey);

  /// Models enabled for the chat picker. Newly discovered models stay off
  /// until the user turns them on.
  final List<String> models;

  /// Ollama only: the `num_ctx` window to request. Ollama's own default is
  /// small, and the Operator's tool list alone needs a few thousand tokens.
  final int? contextLength;

  ProviderConfig copyWith({
    String? name,
    ProviderKind? kind,
    String? baseUrl,
    String? apiKey,
    bool clearApiKey = false,
    List<String>? models,
    int? contextLength,
    bool clearContextLength = false,
  }) => ProviderConfig(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: clearApiKey ? null : apiKey ?? this.apiKey,
    models: models ?? this.models,
    contextLength: clearContextLength
        ? null
        : contextLength ?? this.contextLength,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'baseUrl': baseUrl,
    if (apiKey != null) 'apiKey': apiKey,
    'models': models,
    'contextLength': ?contextLength,
  };

  factory ProviderConfig.fromJson(Json json) => ProviderConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: ProviderKind.values.byName(json['kind'] as String),
    baseUrl: json['baseUrl'] as String,
    apiKey: json['apiKey'] as String?,
    models: ((json['models'] as List?) ?? const []).cast<String>(),
    contextLength: json['contextLength'] as int?,
  );
}
