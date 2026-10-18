import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import '../core/prefs.dart';

const _storageKey = 'mcpm.settings.v1';

class AppSettings {
  const AppSettings({
    this.maxSteps = 12,
    this.extraInstructions = '',
    this.confirmReadOnly = false,
    this.autoCompact = true,
  });

  /// How many model turns one request may take (tool loop limit).
  final int maxSteps;

  /// Added to the Operator's system prompt.
  final String extraInstructions;

  /// Ask before running read-only tools too.
  final bool confirmReadOnly;

  /// Shorten or summarize old messages before they overflow the model's
  /// context window.
  final bool autoCompact;

  AppSettings copyWith({
    int? maxSteps,
    String? extraInstructions,
    bool? confirmReadOnly,
    bool? autoCompact,
  }) => AppSettings(
    maxSteps: maxSteps ?? this.maxSteps,
    extraInstructions: extraInstructions ?? this.extraInstructions,
    confirmReadOnly: confirmReadOnly ?? this.confirmReadOnly,
    autoCompact: autoCompact ?? this.autoCompact,
  );

  Json toJson() => {
    'maxSteps': maxSteps,
    'extraInstructions': extraInstructions,
    'confirmReadOnly': confirmReadOnly,
    'autoCompact': autoCompact,
  };

  factory AppSettings.fromJson(Json json) => AppSettings(
    maxSteps: ((json['maxSteps'] as num?)?.toInt() ?? 12).clamp(2, 30),
    extraInstructions: json['extraInstructions'] as String? ?? '',
    confirmReadOnly: json['confirmReadOnly'] as bool? ?? false,
    autoCompact: json['autoCompact'] as bool? ?? true,
  );
}

final appSettingsProvider = NotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);

class AppSettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    if (raw is! Map) return const AppSettings();
    try {
      return AppSettings.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return const AppSettings();
    }
  }

  void update(AppSettings Function(AppSettings) change) {
    state = change(state);
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, state.toJson());
  }
}
