import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../core/prefs.dart';
import '../core/url.dart';
import '../mcp/mcp_hub.dart';
import '../mcp/mcp_models.dart';
import '../rules/tool_rules_store.dart';
import 'portal_api.dart';
import 'portal_models.dart';

const _storageKey = 'mcpm.portal.v1';

/// Where the gateway is and the token that manages it. The token lives in this
/// browser only, like every other credential the app keeps.
class PortalSettings {
  const PortalSettings({this.url = '', this.token = ''});
  final String url;
  final String token;

  bool get configured => url.isNotEmpty && token.isNotEmpty;

  Json toJson() => {'url': url, 'token': token};

  factory PortalSettings.fromJson(Json json) => PortalSettings(
    url: json['url'] as String? ?? '',
    token: json['token'] as String? ?? '',
  );
}

enum PortalConnection { notConfigured, connecting, connected, failed }

/// Everything the Portals page shows, as last read from the gateway.
class PortalData {
  const PortalData({
    this.settings = const PortalSettings(),
    this.connection = PortalConnection.notConfigured,
    this.error,
    this.status,
    this.servers = const [],
    this.portals = const [],
    this.tokens = const [],
    this.refreshedAt,
  });

  final PortalSettings settings;
  final PortalConnection connection;
  final String? error;
  final GatewayStatus? status;
  final List<GatewayServer> servers;
  final List<GatewayPortal> portals;
  final List<GatewayToken> tokens;
  final DateTime? refreshedAt;

  bool get connected => connection == PortalConnection.connected;

  GatewayServer? server(String id) =>
      servers.where((s) => s.id == id).firstOrNull;
  GatewayPortal? portal(String id) =>
      portals.where((p) => p.id == id).firstOrNull;

  PortalData copyWith({
    PortalSettings? settings,
    PortalConnection? connection,
    String? error,
    bool clearError = false,
    GatewayStatus? status,
    List<GatewayServer>? servers,
    List<GatewayPortal>? portals,
    List<GatewayToken>? tokens,
    DateTime? refreshedAt,
  }) => PortalData(
    settings: settings ?? this.settings,
    connection: connection ?? this.connection,
    error: clearError ? null : error ?? this.error,
    status: status ?? this.status,
    servers: servers ?? this.servers,
    portals: portals ?? this.portals,
    tokens: tokens ?? this.tokens,
    refreshedAt: refreshedAt ?? this.refreshedAt,
  );
}

/// The HTTP client used for the gateway. Tests replace it.
final portalHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final portalControllerProvider = NotifierProvider<PortalController, PortalData>(
  PortalController.new,
);

class PortalController extends Notifier<PortalData> {
  @override
  PortalData build() {
    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    var settings = const PortalSettings();
    if (raw is Map) {
      try {
        settings = PortalSettings.fromJson(raw.cast<String, dynamic>());
      } catch (_) {}
    }
    return PortalData(
      settings: settings,
      connection: settings.configured
          ? PortalConnection.connecting
          : PortalConnection.notConfigured,
    );
  }

  /// The api for the saved settings, or null when none are saved.
  PortalApi? get _maybeApi {
    final settings = state.settings;
    if (!settings.configured) return null;
    return PortalApi(
      baseUrl: settings.url,
      token: settings.token,
      client: ref.read(portalHttpClientProvider),
    );
  }

  PortalApi get _api {
    final api = _maybeApi;
    if (api == null) throw PortalApiException('Connect to a gateway first.');
    return api;
  }

  /// Checks the address and token, saves them and loads the gateway.
  /// Returns an error message, or null on success.
  Future<String?> connect(String url, String token) async {
    final normalized = normalizeBaseUrl(url).replaceAll(RegExp(r'/+$'), '');
    if (!isValidHttpUrl(normalized)) {
      return 'Enter the gateway address, for example http://localhost:8787.';
    }
    final secret = token.trim();
    if (secret.isEmpty) return 'Enter the admin token.';

    final api = PortalApi(
      baseUrl: normalized,
      token: secret,
      client: ref.read(portalHttpClientProvider),
    );
    state = state.copyWith(
      connection: PortalConnection.connecting,
      clearError: true,
    );
    try {
      final status = await api.status();
      final settings = PortalSettings(url: normalized, token: secret);
      await writeJson(
        ref.read(sharedPreferencesProvider),
        _storageKey,
        settings.toJson(),
      );
      state = state.copyWith(settings: settings, status: status);
      await refresh();
      return null;
    } on PortalApiException catch (e) {
      state = state.copyWith(
        connection: state.settings.configured
            ? PortalConnection.failed
            : PortalConnection.notConfigured,
        error: e.message,
      );
      return e.message;
    }
  }

  /// Forgets the gateway (it keeps running; only this app lets go of it).
  Future<void> disconnect() async {
    await ref.read(sharedPreferencesProvider).remove(_storageKey);
    state = const PortalData();
  }

  /// Re-reads everything from the gateway.
  Future<void> refresh() async {
    if (_maybeApi == null) return;
    state = state.copyWith(
      connection: PortalConnection.connecting,
      clearError: true,
    );
    await _load(reportFailure: true);
  }

  /// Newest load wins: a slow read that started before a change must not
  /// overwrite what a later read (after the change) already showed.
  int _loads = 0;

  Future<void> _load({required bool reportFailure}) async {
    final api = _maybeApi;
    if (api == null) return;
    final mine = ++_loads;
    try {
      final results = await Future.wait<Object>([
        api.status(),
        api.servers(),
        api.portals(),
        api.tokens(),
      ]);
      if (mine != _loads) return;
      state = state.copyWith(
        connection: PortalConnection.connected,
        status: results[0] as GatewayStatus,
        servers: results[1] as List<GatewayServer>,
        portals: results[2] as List<GatewayPortal>,
        tokens: results[3] as List<GatewayToken>,
        refreshedAt: DateTime.now(),
        clearError: true,
      );
    } on PortalApiException catch (e) {
      // After a change that went through, a failed re-read keeps what is shown.
      if (mine != _loads || !reportFailure) return;
      state = state.copyWith(
        connection: PortalConnection.failed,
        error: e.message,
      );
    }
  }

  // ----------------------------------------------------------------- servers

  /// Sends this app's server to the gateway under the same id, so tool rules
  /// written here apply there too. Includes its headers, tokens among them.
  Future<GatewayServer> publishServer(McpServerConfig config) async {
    final saved = await _api.saveServer(
      id: config.id,
      name: config.name,
      url: config.url,
      headers: config.headers,
      transport: config.transport.wire,
      enabled: config.enabled,
    );
    await _reload();
    return saved;
  }

  /// Whether the gateway can use [config]: servers that need this browser's
  /// OAuth sign-in cannot be reached from the gateway.
  static bool publishable(McpServerConfig config) => !config.oauth;

  Future<void> removeServer(String id) async {
    await _api.deleteServer(id);
    await _reload();
  }

  Future<GatewayTestResult> testServer(String id) => _api.testServer(id);

  /// Replaces the gateway's tool rules and hidden-tool settings with this
  /// app's. Returns how many rules and overrides were sent.
  Future<({int rules, int overrides})> pushRules() async {
    final rules = ref.read(toolRulesProvider);
    await _api.putRules({
      'rules': [for (final r in rules.rules) r.toJson()],
      'overrides': {
        for (final e in rules.overrides.entries) e.key: e.value.toJson(),
      },
    });
    await _reload();
    return (rules: rules.rules.length, overrides: rules.overrides.length);
  }

  // ----------------------------------------------------------------- portals

  Future<GatewayPortal> savePortal({
    String? id,
    required String name,
    String? slug,
    String? description,
    bool? enabled,
    List<GatewayPortalServer>? servers,
    List<String>? excludedTools,
  }) async {
    final saved = await _api.savePortal(
      id: id,
      name: name,
      slug: slug,
      description: description,
      enabled: enabled,
      servers: servers,
      excludedTools: excludedTools,
    );
    await _reload();
    return saved;
  }

  Future<void> deletePortal(String id) async {
    await _api.deletePortal(id);
    await _reload();
  }

  Future<GatewayToolList> portalTools(
    String id, {
    bool includeHidden = true,
    bool refresh = false,
  }) => _api.portalTools(id, includeHidden: includeHidden, refresh: refresh);

  // ------------------------------------------------------------------ tokens

  Future<CreatedToken> createToken({
    required String name,
    List<String> portalIds = const [],
    int? expiresInDays,
  }) async {
    final created = await _api.createToken(
      name: name,
      portalIds: portalIds,
      expiresInDays: expiresInDays,
    );
    await _reload();
    return created;
  }

  Future<void> revokeToken(String id) async {
    await _api.revokeToken(id);
    await _reload();
  }

  // ------------------------------------------------------------------- audit

  Future<List<GatewayEvent>> audit({
    int limit = 100,
    String? portalId,
    String? status,
    String? query,
  }) => _api.audit(
    limit: limit,
    portalId: portalId,
    status: status,
    query: query,
  );

  /// Refreshes the lists after a change.
  Future<void> _reload() => _load(reportFailure: false);
}

/// Ids of this app's servers that the gateway does not have yet.
List<McpServerConfig> unpublishedServers(McpHubState hub, PortalData data) => [
  for (final s in hub.servers)
    if (data.server(s.config.id) == null) s.config,
];
