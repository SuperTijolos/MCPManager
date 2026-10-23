import 'dart:io';

/// How the gateway is run, read from the environment.
class GatewayConfig {
  GatewayConfig({
    this.host = '127.0.0.1',
    this.port = 8787,
    String? dataDir,
    this.adminToken,
    this.publicBaseUrl,
    List<String>? allowedOrigins,
  }) : dataDir = dataDir ?? 'data',
       allowedOrigins = allowedOrigins ?? const [];

  /// Loopback by default: put a reverse proxy or tunnel in front to publish it.
  final String host;
  final int port;
  final String dataDir;

  /// The admin token; when null one is generated and shown once at first start.
  final String? adminToken;

  /// The public origin clients use (for OAuth metadata and endpoint links).
  final String? publicBaseUrl;

  /// Extra browser origins allowed to call the admin API, besides localhost.
  final List<String> allowedOrigins;

  factory GatewayConfig.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    List<String> csv(String? v) => [
      for (final p in (v ?? '').split(','))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    return GatewayConfig(
      host: e['PORTAL_HOST'] ?? '127.0.0.1',
      port: int.tryParse(e['PORTAL_PORT'] ?? '') ?? 8787,
      dataDir: e['PORTAL_DATA_DIR'] ?? 'data',
      adminToken: e['PORTAL_ADMIN_TOKEN'],
      publicBaseUrl: e['PORTAL_PUBLIC_URL']?.replaceAll(RegExp(r'/+$'), ''),
      allowedOrigins: csv(e['PORTAL_ALLOWED_ORIGINS']),
    );
  }
}
