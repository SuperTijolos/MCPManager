import 'package:mcp_core/mcp_core.dart';

/// One call that went through a portal.
class GatewayAuditEvent {
  GatewayAuditEvent({
    required this.id,
    required this.timestamp,
    this.portalId,
    this.portalSlug,
    required this.principal,
    required this.status,
    this.source = 'portal',
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
    this.conversationId,
  });

  final String id;
  final DateTime timestamp;

  /// The portal the call came through; null for the dashboard's own calls.
  final String? portalId;
  final String? portalSlug;

  /// Who called: `{kind: token|oauth, id, name}`.
  final Json principal;

  /// `success`, `error` or `denied`.
  final String status;

  /// Where the call came from: `portal` (an MCP client), `dashboard` (the
  /// test bench) or `chat`.
  final String source;
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

  /// The dashboard chat the call belongs to, when it came from one.
  final String? conversationId;

  Json toJson() => {
    'id': id,
    'ts': timestamp.toUtc().toIso8601String(),
    'portalId': ?portalId,
    'portalSlug': ?portalSlug,
    'principal': principal,
    'status': status,
    if (source != 'portal') 'source': source,
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
    'conversationId': ?conversationId,
  };

  factory GatewayAuditEvent.fromJson(Json json) => GatewayAuditEvent(
    id: json['id'] as String,
    timestamp: DateTime.parse(json['ts'] as String),
    portalId: json['portalId'] as String?,
    portalSlug: json['portalSlug'] as String?,
    principal: ((json['principal'] as Map?) ?? const {})
        .cast<String, dynamic>(),
    status: json['status'] as String,
    source: json['source'] as String? ?? 'portal',
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
    conversationId: json['conversationId'] as String?,
  );
}

/// Where calls are recorded.
abstract class GatewayAuditLog {
  /// Keeps the latest [capacity] events in memory only, for tests.
  factory GatewayAuditLog.memory({int capacity}) = MemoryAuditLog;

  Future<void> record(GatewayAuditEvent event);

  /// Newest first.
  Future<List<GatewayAuditEvent>> recent({
    int limit = 100,
    String? portalId,
    String? status,
    String? query,
    String? source,
    String? conversationId,
  });

  /// Waits for events still being written.
  Future<void> flush();
}

class MemoryAuditLog implements GatewayAuditLog {
  MemoryAuditLog({this.capacity = 1000});

  final int capacity;
  final List<GatewayAuditEvent> _recent = []; // oldest first

  @override
  Future<void> record(GatewayAuditEvent event) async {
    _recent.add(event);
    if (_recent.length > capacity) _recent.removeAt(0);
  }

  @override
  Future<List<GatewayAuditEvent>> recent({
    int limit = 100,
    String? portalId,
    String? status,
    String? query,
    String? source,
    String? conversationId,
  }) async {
    final q = query?.toLowerCase();
    final out = <GatewayAuditEvent>[];
    for (final e in _recent.reversed) {
      if (portalId != null && e.portalId != portalId) continue;
      if (status != null && e.status != status) continue;
      if (source != null && e.source != source) continue;
      if (conversationId != null && e.conversationId != conversationId) {
        continue;
      }
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

  @override
  Future<void> flush() async {}
}
