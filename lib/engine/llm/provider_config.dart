import '../core/json.dart';

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
  });

  final String id;
  final String name;
  final ProviderKind kind;

  /// Ollama: `http://host:11434`. OpenAI-compatible: `https://host/v1`.
  final String baseUrl;
  final String? apiKey;

  /// Models enabled for the chat picker. Newly discovered models stay off
  /// until the user turns them on.
  final List<String> models;

  ProviderConfig copyWith({
    String? name,
    ProviderKind? kind,
    String? baseUrl,
    String? apiKey,
    bool clearApiKey = false,
    List<String>? models,
  }) => ProviderConfig(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: clearApiKey ? null : apiKey ?? this.apiKey,
    models: models ?? this.models,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'baseUrl': baseUrl,
    if (apiKey != null) 'apiKey': apiKey,
    'models': models,
  };

  factory ProviderConfig.fromJson(Json json) => ProviderConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: ProviderKind.values.byName(json['kind'] as String),
    baseUrl: json['baseUrl'] as String,
    apiKey: json['apiKey'] as String?,
    models: ((json['models'] as List?) ?? const []).cast<String>(),
  );
}
