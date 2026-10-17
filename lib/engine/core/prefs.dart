import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'env.dart';

/// Overridden in `main()` (and in tests) with real instances.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not overridden'),
);

final appEnvProvider = Provider<AppEnv>((ref) => const AppEnv());

Object? readJson(SharedPreferences prefs, String key) {
  final raw = prefs.getString(key);
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

Future<void> writeJson(SharedPreferences prefs, String key, Object value) =>
    prefs.setString(key, jsonEncode(value));
