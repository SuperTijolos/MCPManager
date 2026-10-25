import 'dart:async';

import 'package:mcp_core/mcp_core.dart';

import 'audit.dart';
import 'events.dart';
import 'models.dart';
import 'state.dart';
import 'upstream.dart';

/// What the gateway last saw of one upstream server.
class ServerHealth {
  const ServerHealth({
    required this.ok,
    required this.checkedAt,
    this.error,
    this.toolCount = 0,
  });

  final bool ok;
  final DateTime checkedAt;
  final String? error;
  final int toolCount;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'error': error,
    'toolCount': toolCount,
  };
}

/// Checks the enabled upstream servers every [interval] and announces the
/// ones that went up or down, so the dashboard need not poll.
class HealthMonitor {
  HealthMonitor({
    required this.store,
    required this.pool,
    required this.bus,
    required this.audit,
    this.interval = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final StateStore store;
  final UpstreamPool pool;
  final EventBus bus;
  final GatewayAuditLog audit;
  final Duration interval;
  final DateTime Function() _now;

  final _last = <String, ServerHealth>{};
  Timer? _timer;
  Future<void>? _running;

  Map<String, ServerHealth> get snapshot => Map.unmodifiable(_last);

  /// Starts the periodic checks; an [interval] of zero keeps them off.
  void start() {
    if (interval <= Duration.zero || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => checkAll());
    checkAll();
  }

  /// Checks every enabled server now (overlapping calls share one run).
  Future<void> checkAll() => _running ??= _check().whenComplete(() {
    _running = null;
  });

  Future<void> _check() async {
    final servers = [
      for (final s in store.state.servers)
        if (s.enabled) s,
    ];
    _last.removeWhere((id, _) => servers.every((s) => s.id != id));
    await Future.wait([for (final s in servers) _checkOne(s)]);
  }

  Future<void> _checkOne(UpstreamServer server) async {
    final catalog = await pool.catalog(server, refresh: true);
    await _record(server, catalog);
  }

  /// Records what a check elsewhere (the "test" button) found.
  void note(UpstreamServer server, UpstreamCatalog catalog) {
    unawaited(_record(server, catalog));
  }

  /// Like [note], and completes once it has been written.
  Future<void> recorded(UpstreamServer server, UpstreamCatalog catalog) =>
      _record(server, catalog);

  Future<void> _record(UpstreamServer server, UpstreamCatalog catalog) async {
    final health = ServerHealth(
      ok: catalog.ok,
      checkedAt: _now(),
      error: catalog.error,
      toolCount: catalog.tools.length,
    );
    final before = _last[server.id];
    _last[server.id] = health;
    if (before != null && before.ok == health.ok) return;
    bus.emit('health', {'serverId': server.id, ...health.toJson()});
    // The audit log shows each time a server came up or went down.
    final info = catalog.info;
    await audit.record(
      GatewayAuditEvent.system(
        id: newId('evt'),
        timestamp: _now(),
        kind: 'serverConnect',
        status: health.ok ? 'success' : 'error',
        serverId: server.id,
        serverName: server.name,
        result: health.ok
            ? '${info?.name ?? server.name} ${info?.version ?? ''} · '
                  '${catalog.tools.length} tools'
            : null,
        error: health.ok ? null : redactText(catalog.error ?? 'Unreachable'),
      ),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
