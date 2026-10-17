import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import '../core/prefs.dart';

const _storageKey = 'mcpm.settings.v1';

class AppSettings {
  const AppSettings({
    this.maxSteps = 12,
    this.extraInstructions = '',
    this.confirmReadOnly = false,
  });

  /// How many model turns one request may take (tool loop limit).
  final int maxSteps;

  /// Added to the Operator's system prompt.
  final String extraInstructions;

  /// Ask before running read-only tools too.
  final bool confirmReadOnly;

  AppSettings copyWith({
    int? maxSteps,
    String? extraInstructions,
    bool? confirmReadOnly,
  }) => AppSettings(
    maxSteps: maxSteps ?? this.maxSteps,
    extraInstructions: extraInstructions ?? this.extraInstructions,
    confirmReadOnly: confirmReadOnly ?? this.confirmReadOnly,
  );

  Json toJson() => {
    'maxSteps': maxSteps,
    'extraInstructions': extraInstructions,
    'confirmReadOnly': confirmReadOnly,
  };

  factory AppSettings.fromJson(Json json) => AppSettings(
    maxSteps: ((json['maxSteps'] as num?)?.toInt() ?? 12).clamp(2, 30),
    extraInstructions: json['extraInstructions'] as String? ?? '',
    confirmReadOnly: json['confirmReadOnly'] as bool? ?? false,
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
