import 'dart:io';

/// How the gateway is run, read from the environment.
class GatewayConfig {
  GatewayConfig({
    this.host = '127.0.0.1',
    this.port = 8787,
    this.databaseUrl,
    this.migrationsDir,
    this.adminToken,
    this.publicBaseUrl,
    List<String>? allowedOrigins,
    this.githubClientId,
    this.githubClientSecret,
    List<String>? githubOrgs,
    List<String>? githubUsers,
    this.githubUrl = 'https://github.com',
    this.githubApiUrl = 'https://api.github.com',
    this.sessionDays = 7,
    this.eventHeartbeat = const Duration(seconds: 25),
    this.healthInterval = const Duration(minutes: 1),
    this.maxChatsPerOwner = 200,
  }) : githubOrgs = githubOrgs ?? const [],
       githubUsers = githubUsers ?? const [],
       allowedOrigins = allowedOrigins ?? const [];

  /// Loopback by default: put a reverse proxy or tunnel in front to publish it.
  final String host;
  final int port;

  /// `postgresql://user:pass@host:5432/db` (add `?sslmode=disable` for a local
  /// database without TLS). Required to run; only tests go without.
  final String? databaseUrl;

  /// Where the SQL migrations are; found automatically from the repository.
  final String? migrationsDir;

  /// The admin token; when null one is generated and shown once at first start.
  final String? adminToken;

  /// The public origin clients use (for OAuth metadata and endpoint links).
  final String? publicBaseUrl;

  /// Extra browser origins allowed to call the admin API, besides localhost.
  final List<String> allowedOrigins;

  /// GitHub OAuth app used to sign people in to the dashboard.
  final String? githubClientId;
  final String? githubClientSecret;

  /// Who may sign in: members of any of these organisations, or these users.
  /// With both empty nobody can.
  final List<String> githubOrgs;
  final List<String> githubUsers;

  /// Change both for GitHub Enterprise Server.
  final String githubUrl;
  final String githubApiUrl;

  /// Conversations kept per person; the least recently used go first.
  final int maxChatsPerOwner;

  /// How often the upstream servers are checked; zero turns it off.
  final Duration healthInterval;

  /// How often an idle event stream sends a keep-alive.
  final Duration eventHeartbeat;

  /// How long a dashboard sign-in lasts.
  final int sessionDays;

  bool get githubConfigured =>
      (githubClientId ?? '').isNotEmpty &&
      (githubClientSecret ?? '').isNotEmpty;

  factory GatewayConfig.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    List<String> csv(String? v) => [
      for (final p in (v ?? '').split(','))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    return GatewayConfig(
      host: e['PORTAL_HOST'] ?? '127.0.0.1',
      port: int.tryParse(e['PORTAL_PORT'] ?? '') ?? 8787,
      databaseUrl: e['DATABASE_URL'],
      migrationsDir: e['PORTAL_MIGRATIONS_DIR'],
      adminToken: e['PORTAL_ADMIN_TOKEN'],
      publicBaseUrl:
          e['PORTAL_PUBLIC_URL'] == null || e['PORTAL_PUBLIC_URL']!.isEmpty
          ? null
          : e['PORTAL_PUBLIC_URL']!.replaceAll(RegExp(r'/+$'), ''),
      allowedOrigins: csv(e['PORTAL_ALLOWED_ORIGINS']),
      githubClientId: e['GITHUB_CLIENT_ID'],
      githubClientSecret: e['GITHUB_CLIENT_SECRET'],
      githubOrgs: csv(e['DASHBOARD_GITHUB_ORGS']),
      githubUsers: csv(e['DASHBOARD_GITHUB_USERS']),
      githubUrl: (e['GITHUB_URL'] ?? 'https://github.com').replaceAll(
        RegExp(r'/+$'),
        '',
      ),
      githubApiUrl: (e['GITHUB_API_URL'] ?? 'https://api.github.com')
          .replaceAll(RegExp(r'/+$'), ''),
      sessionDays: int.tryParse(e['PORTAL_SESSION_DAYS'] ?? '') ?? 7,
      healthInterval: Duration(
        seconds: int.tryParse(e['PORTAL_HEALTH_SECONDS'] ?? '') ?? 60,
      ),
    );
  }
}
