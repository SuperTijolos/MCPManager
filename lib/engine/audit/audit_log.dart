import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/prefs.dart';
import 'audit_models.dart';

const _storageKey = 'mcpm.audit.v1';
const auditCapacity = 1000;

/// Browsers give localStorage about 5 MB for everything; keep the audit log
/// well under that by dropping the oldest events if it gets too big.
const _maxStoredChars = 2500000;

final auditLogProvider = NotifierProvider<AuditLog, List<AuditEvent>>(
  AuditLog.new,
);

/// Newest-first, capped, persisted. Append-only from the app's point of view:
/// there is no API to edit an event, only [clear] for the whole log.
class AuditLog extends Notifier<List<AuditEvent>> {
  @override
  List<AuditEvent> build() {
    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    if (raw is! List) return const [];
    final events = <AuditEvent>[];
    for (final item in raw) {
      try {
        events.add(AuditEvent.fromJson((item as Map).cast<String, dynamic>()));
      } catch (_) {
        // Skip records written by an incompatible version.
      }
    }
    return events;
  }

  AuditEvent record({
    required AuditKind kind,
    required AuditStatus status,
    required AuditSource source,
    required String actor,
    String? serverId,
    String? serverName,
    String? toolName,
    int? durationMs,
    String? args,
    String? forwarded,
    String? context,
    String? result,
    String? error,
    String? approval,
    String? conversationId,
  }) {
    final event = AuditEvent(
      id: newId('evt'),
      timestamp: DateTime.now(),
      kind: kind,
      status: status,
      source: source,
      actor: actor,
      serverId: serverId,
      serverName: serverName,
      toolName: toolName,
      durationMs: durationMs,
      args: args,
      forwarded: forwarded,
      context: context,
      result: result,
      error: error,
      approval: approval,
      conversationId: conversationId,
    );
    final next = [event, ...state];
    state = next.length > auditCapacity ? next.sublist(0, auditCapacity) : next;
    _persist();
    return event;
  }

  /// Deletes the events [test] accepts; returns how many went.
  int removeWhere(bool Function(AuditEvent) test) {
    final kept = [
      for (final e in state)
        if (!test(e)) e,
    ];
    final removed = state.length - kept.length;
    if (removed == 0) return 0;
    state = kept;
    _persist();
    return removed;
  }

  void clear() {
    state = const [];
    _persist();
  }

  void _persist() {
    var json = [for (final e in state) e.toJson()];
    var size = jsonEncode(json).length;
    while (size > _maxStoredChars && state.length > 50) {
      state = state.sublist(0, (state.length * 0.8).floor());
      json = [for (final e in state) e.toJson()];
      size = jsonEncode(json).length;
    }
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, json);
  }
}
