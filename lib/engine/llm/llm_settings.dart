import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/prefs.dart';
import '../server/server_client.dart';
import '../server/server_events.dart';
import '../server/session.dart';
import 'llm_types.dart';
import 'ollama_provider.dart';
import 'openai_provider.dart';
import 'provider_config.dart';

const _activeKey = 'mcpm.llm.active.v1';

/// Gemma 4 on Ollama is the suggested default; any other model name can be
/// typed in.
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

/// Builds the client for a provider. The dashboard never holds a provider's
/// key: the client talks to the server's proxy for that provider (signed in
/// with the session), and the server adds the key. Overridden in tests to
/// return a fake provider.
final llmProviderFactoryProvider =
    Provider<LlmProvider Function(ProviderConfig)>((ref) {
      final session = ref.watch(sessionProvider);
      return (config) {
        final proxied = config.copyWith(
          baseUrl: '${session.serverUrl}/api/llm/providers/${config.id}/proxy',
          apiKey: session.token,
        );
        return switch (config.kind) {
          ProviderKind.ollama => OllamaLlmProvider(proxied),
          ProviderKind.openaiCompatible => OpenAiLlmProvider(proxied),
        };
      };
    });

final llmSettingsProvider = NotifierProvider<LlmSettingsNotifier, LlmSettings>(
  LlmSettingsNotifier.new,
);

/// The model providers, kept on the server (with their keys). Which provider
/// and model this browser chats with is a local preference.
class LlmSettingsNotifier extends Notifier<LlmSettings> {
  ServerClient? _client;
  Completer<void>? _loaded;

  /// Completes when the first load has finished.
  Future<void> get loaded => (_loaded ??= Completer<void>()).future;

  @override
  LlmSettings build() {
    _client = ref.watch(serverClientProvider);
    _loaded = Completer<void>();
    listenToServer(ref, (e) {
      if (e.type == 'ready' ||
          (e.type == 'changed' &&
              ((e.data['collections'] as List?) ?? const []).contains(
                'llmProviders',
              ))) {
        unawaited(reload());
      }
    });
    if (_client != null) {
      Future.microtask(() async {
        await reload();
        if (ref.mounted && !(_loaded?.isCompleted ?? true)) {
          _loaded!.complete();
        }
      });
    } else {
      _loaded!.complete();
    }
    final active = readJson(ref.read(sharedPreferencesProvider), _activeKey);
    return LlmSettings(
      providers: const [],
      activeProviderId: active is Map ? active['providerId'] as String? : null,
      activeModel: active is Map ? active['model'] as String? : null,
    );
  }

  /// Loads the providers from the server.
  Future<void> reload() async {
    final client = _client;
    if (client == null) return;
    try {
      final list = await client.getList('/api/llm/providers');
      if (!ref.mounted) return;
      _setProviders([for (final j in list) ProviderConfig.fromServer(j)]);
    } on ServerException {
      // Keep what is shown.
    }
  }

  void _setProviders(List<ProviderConfig> providers) {
    var activeId = state.activeProviderId;
    var model = state.activeModel;
    if (!providers.any((p) => p.id == activeId)) {
      final first = providers.firstOrNull;
      activeId = first?.id;
      model = first?.models.firstOrNull;
    }
    state = LlmSettings(
      providers: providers,
      activeProviderId: activeId,
      activeModel: model,
    );
    _saveActive();
  }

  /// Adds [config] or replaces the provider with the same id. A key typed in
  /// [ProviderConfig.apiKey] replaces the stored one; [clearKey] removes it.
  /// Throws [ServerException] if the server refuses it (the list is then
  /// restored).
  Future<void> upsert(ProviderConfig config, {bool clearKey = false}) async {
    final exists = state.providers.any((p) => p.id == config.id);
    final shown = config.copyWith(
      hasKey: clearKey
          ? false
          : (config.apiKey ?? '').isNotEmpty || config.hasKey,
      clearApiKey: true,
    );
    final providers = exists
        ? [for (final p in state.providers) p.id == config.id ? shown : p]
        : [...state.providers, shown];
    final activeId = state.activeProviderId ?? config.id;
    var activeModel = state.activeModel;
    if (activeId == config.id && !config.models.contains(activeModel)) {
      activeModel = config.models.firstOrNull;
    }
    state = LlmSettings(
      providers: providers,
      activeProviderId: activeId,
      activeModel: activeModel,
    );
    _saveActive();
    final client = _client;
    if (client == null) return;
    try {
      final saved = await client.putMap(
        '/api/llm/providers/${config.id}',
        config.toServerJson(clearKey: clearKey),
      );
      if (!ref.mounted) return;
      final fresh = ProviderConfig.fromServer(saved);
      state = LlmSettings(
        providers: [
          for (final p in state.providers) p.id == fresh.id ? fresh : p,
        ],
        activeProviderId: state.activeProviderId,
        activeModel: state.activeModel,
      );
    } on ServerException {
      await reload();
      rethrow;
    }
  }

  Future<void> remove(String id) async {
    final providers = [
      for (final p in state.providers)
        if (p.id != id) p,
    ];
    final removedActive = state.activeProviderId == id;
    final next = removedActive && providers.isNotEmpty ? providers.first : null;
    state = LlmSettings(
      providers: providers,
      activeProviderId: removedActive ? next?.id : state.activeProviderId,
      activeModel: removedActive
          ? (next != null && next.models.isNotEmpty ? next.models.first : null)
          : state.activeModel,
    );
    _saveActive();
    final client = _client;
    if (client == null) return;
    try {
      await client.delete('/api/llm/providers/$id');
    } on ServerException {
      await reload();
      rethrow;
    }
  }

  void setActive(String providerId, String model) {
    state = LlmSettings(
      providers: state.providers,
      activeProviderId: providerId,
      activeModel: model,
    );
    _saveActive();
  }

  void _saveActive() => writeJson(
    ref.read(sharedPreferencesProvider),
    _activeKey,
    {'providerId': state.activeProviderId, 'model': state.activeModel},
  );
}
