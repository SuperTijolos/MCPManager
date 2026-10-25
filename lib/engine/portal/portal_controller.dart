import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server/server_client.dart';
import '../server/server_events.dart';
import '../server/session.dart';
import 'portal_api.dart';
import 'portal_models.dart';

enum PortalConnection { notConfigured, connecting, connected, failed }

/// Everything the Portals page shows, as last read from the gateway.
class PortalData {
  const PortalData({
    this.serverUrl = '',
    this.connection = PortalConnection.notConfigured,
    this.error,
    this.status,
    this.servers = const [],
    this.portals = const [],
    this.tokens = const [],
    this.refreshedAt,
  });

  final String serverUrl;
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
    String? serverUrl,
    PortalConnection? connection,
    String? error,
    bool clearError = false,
    GatewayStatus? status,
    List<GatewayServer>? servers,
    List<GatewayPortal>? portals,
    List<GatewayToken>? tokens,
    DateTime? refreshedAt,
  }) => PortalData(
    serverUrl: serverUrl ?? this.serverUrl,
    connection: connection ?? this.connection,
    error: clearError ? null : error ?? this.error,
    status: status ?? this.status,
    servers: servers ?? this.servers,
    portals: portals ?? this.portals,
    tokens: tokens ?? this.tokens,
    refreshedAt: refreshedAt ?? this.refreshedAt,
  );
}

final portalControllerProvider = NotifierProvider<PortalController, PortalData>(
  PortalController.new,
);

/// Portals and access tokens, as the server has them. Changes made elsewhere
/// arrive over the event stream.
class PortalController extends Notifier<PortalData> {
  ServerClient? _client;
  Timer? _debounce;
  Completer<void>? _loaded;

  /// Completes when the first load has finished.
  Future<void> get loaded => (_loaded ??= Completer<void>()).future;

  @override
  PortalData build() {
    _client = ref.watch(serverClientProvider);
    final url = ref.watch(sessionProvider).serverUrl ?? '';
    ref.onDispose(() => _debounce?.cancel());
    listenToServer(ref, (e) {
      final what = e.type == 'changed'
          ? ((e.data['collections'] as List?) ?? const [])
          : const [];
      if (e.type == 'ready' ||
          what.any((c) => c == 'portals' || c == 'tokens' || c == 'servers')) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 200), () {
          if (ref.mounted) unawaited(_reload());
        });
      }
    });
    final done = _loaded = Completer<void>();
    if (_client != null) {
      Future.microtask(() async {
        await _load(reportFailure: true);
        if (!done.isCompleted) done.complete();
      });
    } else {
      done.complete();
    }
    return PortalData(
      serverUrl: url,
      connection: _client == null
          ? PortalConnection.notConfigured
          : PortalConnection.connecting,
    );
  }

  PortalApi get _api {
    final client = _client;
    if (client == null) throw PortalApiException('Sign in first.');
    return PortalApi(client);
  }

  /// Re-reads everything from the gateway.
  Future<void> refresh() async {
    if (_client == null) return;
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
    final client = _client;
    if (client == null) return;
    final api = PortalApi(client);
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

  /// Refreshes the lists after a change.
  Future<void> _reload() => _load(reportFailure: false);
}
