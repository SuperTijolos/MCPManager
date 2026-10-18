import '../core/json.dart';

/// Accept raw credentials, quoted credentials, or Bearer-prefixed values.
/// Users sometimes paste the whole header, twice. Never include the prefix
/// more than once in an outgoing Authorization header.
String normalizeApiKey(String? value) {
  var key = (value ?? '').trim();
  for (var i = 0; i < 4; i++) {
    if (key.length >= 2 &&
        ((key.startsWith('"') && key.endsWith('"')) ||
            (key.startsWith("'") && key.endsWith("'")))) {
      key = key.substring(1, key.length - 1).trim();
      continue;
    }
    final bearer = RegExp(r'^Bearer\s+', caseSensitive: false).firstMatch(key);
    if (bearer == null) break;
    key = key.substring(bearer.end).trim();
  }
  return key;
}

/// OpenRouter rejects malformed Bearer tokens with a misleading 401 error:
/// "Missing Authentication header", even if a header was sent. Validate the
/// documented key prefix locally without exposing or transmitting the value.
String? openRouterKeyProblem(String? value) {
  final key = normalizeApiKey(value);
  if (key.isEmpty) return 'OpenRouter requires an API key.';
  if (!key.startsWith('sk-or-v1-')) {
    return 'This is not an OpenRouter API key. OpenRouter keys start with '
        'sk-or-v1-. Copy one from your OpenRouter Keys page.';
  }
  // A standard OpenRouter API key contains exactly 64 lowercase hex digits
  // after the prefix. A truncated or redacted value can otherwise produce a
  // misleading "Missing Authentication header" response from OpenRouter.
  if (!RegExp(r'^sk-or-v1-[0-9a-f]{64}$').hasMatch(key)) {
    return 'Invalid OpenRouter API key format. A complete key starts with '
        'sk-or-v1- followed by 64 lowercase hexadecimal characters. '
        'Copy the full key from OpenRouter (do not paste a masked key).';
  }
  return null;
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
