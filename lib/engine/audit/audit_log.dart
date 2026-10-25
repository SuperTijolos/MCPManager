import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import '../server/server_client.dart';
import '../server/server_events.dart';
import '../server/session.dart';
import 'audit_models.dart';

/// How many recent events the dashboard holds; the server keeps the rest.
const auditCapacity = 1000;

final auditLogProvider = NotifierProvider<AuditLog, List<AuditEvent>>(
  AuditLog.new,
);

/// The most recent events, newest first, as the server recorded them. The
/// server writes every call (from portals, the Tools page and the chat); new
/// ones arrive over the event stream.
class AuditLog extends Notifier<List<AuditEvent>> {
  ServerClient? _client;
  Completer<void>? _loaded;
  Timer? _debounce;

  /// Completes when the first load has finished.
  Future<void> get loaded => (_loaded ??= Completer<void>()).future;

  @override
  List<AuditEvent> build() {
    _client = ref.watch(serverClientProvider);
    _loaded = Completer<void>();
    ref.onDispose(() => _debounce?.cancel());
    listenToServer(ref, _onEvent);
    if (_client != null) {
      Future.microtask(() async {
        await reload();
        if (ref.mounted && !(_loaded?.isCompleted ?? true)) {
          _loaded!.complete();
        }
      });
    } else {
      _loaded!.complete();
    }
    return const [];
  }

  void _onEvent(ServerEvent e) {
    switch (e.type) {
      case 'audit':
        add(AuditEvent.fromServer(e.data));
      case 'audit-deleted':
      case 'ready':
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 150), () {
          if (ref.mounted) unawaited(reload());
        });
    }
  }

  void add(AuditEvent event) {
    if (state.any((e) => e.id == event.id)) return;
    final next = [event, ...state];
    state = next.length > auditCapacity ? next.sublist(0, auditCapacity) : next;
  }

  /// Fetches the newest few events and adds the ones not shown yet: cheap, and
  /// right after something that records on the server (a connect, a sign-in).
  Future<void> catchUp() async {
    final client = _client;
    if (client == null) return;
    try {
      final r = await client.getMap('/api/audit', query: {'limit': '30'});
      if (!ref.mounted) return;
      final fresh = [
        for (final e in (r['events'] as List? ?? const []))
          AuditEvent.fromServer((e as Map).cast<String, dynamic>()),
      ].where((e) => !state.any((x) => x.id == e.id)).toList();
      if (fresh.isEmpty) return;
      final merged = [...fresh, ...state]
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      state = merged.length > auditCapacity
          ? merged.sublist(0, auditCapacity)
          : merged;
    } on ServerException {
      // The stream or the next reload fills it in.
    }
  }

  /// Loads the latest events from the server.
  Future<void> reload() async {
    final client = _client;
    if (client == null) return;
    try {
      final r = await client.getMap(
        '/api/audit',
        query: {'limit': '$auditCapacity'},
      );
      if (!ref.mounted) return;
      state = [
        for (final e in (r['events'] as List? ?? const []))
          AuditEvent.fromServer((e as Map).cast<String, dynamic>()),
      ];
    } on ServerException {
      // Keep what is shown.
    }
  }

  /// Records something the dashboard itself did or saw (a management action by
  /// the Operator). Calls are recorded by the server, not here.
  Future<void> record({
    required AuditKind kind,
    required AuditStatus status,
    required AuditSource source,
    required String actor,
    String? serverId,
    String? serverName,
    String? toolName,
    int? durationMs,
    String? args,
    String? result,
    String? error,
    String? approval,
    String? conversationId,
  }) async {
    final client = _client;
    if (client == null) return;
    try {
      final stored = await client.postMap('/api/audit/events', {
        'kind': kind.name,
        'status': status.name,
        'source': source == AuditSource.workbench ? 'dashboard' : 'chat',
        'actor': actor,
        'serverId': ?serverId,
        'serverName': ?serverName,
        'tool': ?toolName,
        'durationMs': ?durationMs,
        'args': ?args,
        'result': ?result,
        'error': ?error,
        'approval': ?approval,
        'conversationId': ?conversationId,
      });
      if (ref.mounted && stored.isNotEmpty) {
        add(AuditEvent.fromServer(stored));
      }
    } on ServerException {
      // The action happened; only its record is missing.
    }
  }

  /// Deletes the events [test] accepts (among those loaded); returns how many
  /// went.
  Future<int> removeWhere(bool Function(AuditEvent) test) async {
    final client = _client;
    if (client == null) return 0;
    final ids = [
      for (final e in state)
        if (test(e)) e.id,
    ];
    if (ids.isEmpty) return 0;
    final r = await client.postMap('/api/audit/delete', {'ids': ids});
    final gone = ids.toSet();
    if (ref.mounted) {
      state = [
        for (final e in state)
          if (!gone.contains(e.id)) e,
      ];
    }
    return (r['removed'] as num?)?.toInt() ?? ids.length;
  }

  /// Deletes every event, including those older than what is loaded.
  Future<void> clear() async {
    final client = _client;
    if (client == null) return;
    await client.postMap('/api/audit/delete', {'all': true});
    if (ref.mounted) state = const [];
  }
}

/// A JSON object for tests that build events by hand.
Json auditEventJson(AuditEvent e) => e.toJson();
