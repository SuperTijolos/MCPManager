import 'package:env_flutter/env_flutter.dart';

import 'url.dart';

/// Non-secret defaults from the bundled `.env` asset. On web this file is
/// downloadable by anyone who can load the app, so it must never hold secrets.
class AppEnv {
  const AppEnv({this.ollamaUrl});

  final String? ollamaUrl;

  static Future<AppEnv> load() async {
    try {
      await dotenv.load(fileNames: const ['.env']);
    } catch (_) {
      return const AppEnv();
    }
    final raw = dotenv.maybeGet('OLLAMA_URL');
    final url = raw == null ? '' : normalizeBaseUrl(raw);
    return AppEnv(ollamaUrl: url.isEmpty ? null : url);
  }
}
