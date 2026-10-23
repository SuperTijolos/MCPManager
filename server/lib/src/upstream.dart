import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mcp_core/mcp_core.dart';

import 'models.dart';

/// What discovery found on one upstream server.
class UpstreamCatalog {
  const UpstreamCatalog({
    required this.fetchedAt,
    this.info,
    this.tools = const [],
    this.error,
    this.transport,
  });

  final DateTime fetchedAt;
  final McpServerInfo? info;
  final List<McpTool> tools;

  /// Why the server could not be reached, when it could not.
  final String? error;
  final McpTransport? transport;

  bool get ok => error == null;
}

/// Talks to the upstream servers: lists their tools (cached for a short while)
/// and forwards calls, keeping one connection per server and reconnecting
/// when it breaks.
class UpstreamPool {
  UpstreamPool({
    http.Client Function()? clientFactory,
    this.catalogTtl = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _now = clock ?? DateTime.now;

  final http.Client Function() _clientFactory;
  final Duration catalogTtl;
  final DateTime Function() _now;

  final _catalogs = <String, UpstreamCatalog>{};
  final _inflight = <String, Future<UpstreamCatalog>>{};
  final _connections = <String, _Live>{};

  /// The server's tools, from the cache unless it is older than [catalogTtl]
  /// or [refresh] is set. Never throws: a failure is in [UpstreamCatalog.error].
  Future<UpstreamCatalog> catalog(
    UpstreamServer server, {
    bool refresh = false,
  }) {
    final cached = _catalogs[server.id];
    if (!refresh &&
        cached != null &&
        cached.ok &&
        _now().difference(cached.fetchedAt) < catalogTtl) {
      return Future.value(cached);
    }
    return _inflight[server.id] ??= _discover(server).whenComplete(() {
      // A block body: returning the removed future would make it wait on itself.
      _inflight.remove(server.id);
    });
  }

  Future<UpstreamCatalog> _discover(UpstreamServer server) async {
    try {
      final live = await _connect(server);
      final tools = await live.connection.listTools();
      final catalog = UpstreamCatalog(
        fetchedAt: _now(),
        info: live.info,
        tools: tools,
        transport: live.connection.transport,
      );
      _catalogs[server.id] = catalog;
      return catalog;
    } catch (e) {
      await _drop(server.id);
      // Keep serving the last good list rather than hide every tool because of
      // one failed refresh; only a first failure has nothing to fall back on.
      final previous = _catalogs[server.id];
      if (previous != null && previous.ok) {
        return UpstreamCatalog(
          fetchedAt: previous.fetchedAt,
          info: previous.info,
          tools: previous.tools,
          transport: previous.transport,
          error: '$e',
        );
      }
      final failed = UpstreamCatalog(fetchedAt: _now(), error: '$e');
      _catalogs[server.id] = failed;
      return failed;
    }
  }

  /// Calls [tool] on [server]. A broken connection is replaced once.
  Future<McpToolResult> call(
    UpstreamServer server,
    String tool,
    Json arguments,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final live = await _connect(server);
        return await live.connection.callTool(tool, arguments);
      } on McpException catch (e) {
        await _drop(server.id);
        // A reply from the server (auth, JSON-RPC error) will not change by
        // reconnecting; a dropped session or network failure might.
        final worthRetry = e.code == null || e.code == 404 || e.code == 410;
        if (attempt == 0 && worthRetry) continue;
        rethrow;
      } catch (_) {
        await _drop(server.id);
        if (attempt == 0) continue;
        rethrow;
      }
    }
  }

  Future<_Live> _connect(UpstreamServer server) async {
    final existing = _connections[server.id];
    if (existing != null && existing.config == server.toConfigKey) {
      return existing;
    }
    await _drop(server.id);
    final connection = createMcpConnection(
      server.toConfig(),
      httpClient: _clientFactory(),
    );
    final info = await connection.connect();
    final live = _Live(connection, info, server.toConfigKey);
    _connections[server.id] = live;
    return live;
  }

  Future<void> _drop(String id) async {
    final live = _connections.remove(id);
    live?.connection.close();
  }

  /// Forget everything about [serverId] (after it was edited or removed).
  Future<void> invalidate(String serverId) async {
    _catalogs.remove(serverId);
    await _drop(serverId);
  }

  Future<void> close() async {
    for (final id in _connections.keys.toList()) {
      await _drop(id);
    }
  }
}

class _Live {
  _Live(this.connection, this.info, this.config);
  final McpConnection connection;
  final McpServerInfo info;

  /// What the connection was opened with, to notice an edited server.
  final String config;
}

extension on UpstreamServer {
  String get toConfigKey =>
      '$url|$transport|${headers.entries.map((e) => '${e.key}=${e.value}').join('&')}';
}
