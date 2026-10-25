import 'package:env_flutter/env_flutter.dart';

/// Non-secret defaults from the bundled `.env` asset. On web this file is
/// downloadable by anyone who can load the app, so it must never hold secrets.
class AppEnv {
  const AppEnv({this.portalUrl});

  /// Where the server usually is, to prefill the sign-in page (`PORTAL_URL`).
  final String? portalUrl;

  static Future<AppEnv> load() async {
    try {
      await dotenv.load(fileNames: const ['.env']);
    } catch (_) {
      return const AppEnv();
    }
    final portal = (dotenv.maybeGet('PORTAL_URL') ?? '').trim();
    return AppEnv(portalUrl: portal.isEmpty ? null : portal);
  }
}
