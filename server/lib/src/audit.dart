import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_core/mcp_core.dart';

/// One call that went through a portal.
class GatewayAuditEvent {
  GatewayAuditEvent({
    required this.id,
    required this.timestamp,
    required this.portalId,
    required this.portalSlug,
    required this.principal,
    required this.status,
    this.serverId,
    this.serverName,
    this.tool,
    this.exposedName,
    this.durationMs,
    this.args,
    this.forwarded,
    this.context,
    this.result,
    this.error,
    this.rules = const [],
  });

  final String id;
  final DateTime timestamp;
  final String portalId;
  final String portalSlug;

  /// Who called: `{kind: token|oauth, id, name}`.
  final Json principal;

  /// `success`, `error` or `denied`.
  final String status;
  final String? serverId;
  final String? serverName;
  final String? tool;
  final String? exposedName;
  final int? durationMs;
  final String? args;
  final String? forwarded;
  final String? context;
  final String? result;
  final String? error;
  final List<String> rules;

  Json toJson() => {
    'id': id,
    'ts': timestamp.toUtc().toIso8601String(),
    'portalId': portalId,
    'portalSlug': portalSlug,
    'principal': principal,
    'status': status,
    'serverId': ?serverId,
    'serverName': ?serverName,
    'tool': ?tool,
    'exposedName': ?exposedName,
    'durationMs': ?durationMs,
    'args': ?args,
    'forwarded': ?forwarded,
    'context': ?context,
    'result': ?result,
    'error': ?error,
    if (rules.isNotEmpty) 'rules': rules,
  };

  factory GatewayAuditEvent.fromJson(Json json) => GatewayAuditEvent(
    id: json['id'] as String,
    timestamp: DateTime.parse(json['ts'] as String),
    portalId: json['portalId'] as String,
    portalSlug: json['portalSlug'] as String? ?? '',
    principal: ((json['principal'] as Map?) ?? const {})
        .cast<String, dynamic>(),
    status: json['status'] as String,
    serverId: json['serverId'] as String?,
    serverName: json['serverName'] as String?,
    tool: json['tool'] as String?,
    exposedName: json['exposedName'] as String?,
    durationMs: json['durationMs'] as int?,
    args: json['args'] as String?,
    forwarded: json['forwarded'] as String?,
    context: json['context'] as String?,
    result: json['result'] as String?,
    error: json['error'] as String?,
    rules: [for (final r in (json['rules'] as List?) ?? const []) '$r'],
  );
}

/// Appends events to a JSON-lines file and keeps the latest in memory.
class GatewayAuditLog {
  GatewayAuditLog._(this._file, this._recent, this.capacity);

  GatewayAuditLog.memory({this.capacity = 1000}) : _file = null, _recent = [];

  final File? _file;
  final List<GatewayAuditEvent> _recent; // oldest first
  final int capacity;
  Future<void> _queue = Future.value();

  /// Rotate the file past this size.
  static const _maxFileBytes = 10 * 1024 * 1024;

  static Future<GatewayAuditLog> open(File file, {int capacity = 1000}) async {
    final recent = <GatewayAuditEvent>[];
    if (await file.exists()) {
      final lines = await file.readAsLines();
      for (final line in lines.skip(
        lines.length > capacity ? lines.length - capacity : 0,
      )) {
        try {
          recent.add(
            GatewayAuditEvent.fromJson(
              (jsonDecode(line) as Map).cast<String, dynamic>(),
            ),
          );
        } catch (_) {
          // A damaged line is skipped, not fatal.
        }
      }
    } else {
      await file.parent.create(recursive: true);
    }
    return GatewayAuditLog._(file, recent, capacity);
  }

  Future<void> record(GatewayAuditEvent event) {
    _recent.add(event);
    if (_recent.length > capacity) _recent.removeAt(0);
    final file = _file;
    if (file == null) return Future.value();
    _queue = _queue.then((_) async {
      try {
        if (await file.exists() && await file.length() > _maxFileBytes) {
          await file.rename('${file.path}.1');
        }
        await file.writeAsString(
          '${jsonEncode(event.toJson())}\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // Losing a log line must never fail the call that was just served.
      }
    });
    return _queue;
  }

  /// Newest first.
  List<GatewayAuditEvent> recent({
    int limit = 100,
    String? portalId,
    String? status,
    String? query,
  }) {
    final q = query?.toLowerCase();
    final out = <GatewayAuditEvent>[];
    for (final e in _recent.reversed) {
      if (portalId != null && e.portalId != portalId) continue;
      if (status != null && e.status != status) continue;
      if (q != null && q.isNotEmpty) {
        final hay =
            '${e.tool} ${e.exposedName} ${e.serverName} ${e.error} ${e.args} ${e.result}'
                .toLowerCase();
        if (!hay.contains(q)) continue;
      }
      out.add(e);
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<void> flush() => _queue;
}
