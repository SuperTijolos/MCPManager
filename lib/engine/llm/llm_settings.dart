import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/prefs.dart';
import 'llm_types.dart';
import 'ollama_provider.dart';
import 'openai_provider.dart';
import 'provider_config.dart';

const _storageKey = 'mcpm.llm.v1';

/// Gemma 4 on Ollama is the default; any other model name can be typed in.
const defaultOllamaModel = 'gemma4';
const defaultOllamaUrl = 'http://localhost:11434';

class LlmSettings {
  const LlmSettings({
    required this.providers,
    this.activeProviderId,
    this.activeModel,
  });

  final List<ProviderConfig> providers;
  final String? activeProviderId;
  final String? activeModel;

  ProviderConfig? get activeProvider {
    for (final p in providers) {
      if (p.id == activeProviderId) return p;
    }
    return null;
  }

  bool get isReady => activeProvider != null && (activeModel ?? '').isNotEmpty;
}

/// Overridden in tests to return a fake provider.
final llmProviderFactoryProvider =
    Provider<LlmProvider Function(ProviderConfig)>(
      (ref) =>
          (config) => switch (config.kind) {
            ProviderKind.ollama => OllamaLlmProvider(config),
            ProviderKind.openaiCompatible => OpenAiLlmProvider(config),
          },
    );

final llmSettingsProvider = NotifierProvider<LlmSettingsNotifier, LlmSettings>(
  LlmSettingsNotifier.new,
);

class LlmSettingsNotifier extends Notifier<LlmSettings> {
  @override
  LlmSettings build() {
    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    if (raw is Map) {
      try {
        final providers = [
          for (final p in (raw['providers'] as List))
            ProviderConfig.fromJson((p as Map).cast<String, dynamic>()),
        ];
        return LlmSettings(
          providers: providers,
          activeProviderId: raw['activeProviderId'] as String?,
          activeModel: raw['activeModel'] as String?,
        );
      } catch (_) {
        // Fall through to defaults.
      }
    }
    final provider = ProviderConfig(
      id: newId('llm'),
      name: 'Ollama',
      kind: ProviderKind.ollama,
      baseUrl: ref.read(appEnvProvider).ollamaUrl ?? defaultOllamaUrl,
      models: const [defaultOllamaModel],
    );
    return LlmSettings(
      providers: [provider],
      activeProviderId: provider.id,
      activeModel: defaultOllamaModel,
    );
  }

  void upsert(ProviderConfig config) {
    final exists = state.providers.any((p) => p.id == config.id);
    final providers = exists
        ? [for (final p in state.providers) p.id == config.id ? config : p]
        : [...state.providers, config];
    final activeId = state.activeProviderId ?? config.id;
    var activeModel = state.activeModel;
    if (activeId == config.id && !config.models.contains(activeModel)) {
      activeModel = config.models.firstOrNull;
    }
    _set(
      LlmSettings(
        providers: providers,
        activeProviderId: activeId,
        activeModel: activeModel,
      ),
    );
  }

  void remove(String id) {
    final providers = [
      for (final p in state.providers)
        if (p.id != id) p,
    ];
    final removedActive = state.activeProviderId == id;
    final next = removedActive && providers.isNotEmpty ? providers.first : null;
    _set(
      LlmSettings(
        providers: providers,
        activeProviderId: removedActive ? next?.id : state.activeProviderId,
        activeModel: removedActive
            ? (next != null && next.models.isNotEmpty
                  ? next.models.first
                  : null)
            : state.activeModel,
      ),
    );
  }

  void setActive(String providerId, String model) {
    _set(
      LlmSettings(
        providers: state.providers,
        activeProviderId: providerId,
        activeModel: model,
      ),
    );
  }

  void _set(LlmSettings next) {
    state = next;
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, {
      'providers': [for (final p in next.providers) p.toJson()],
      'activeProviderId': next.activeProviderId,
      'activeModel': next.activeModel,
    });
  }
}
