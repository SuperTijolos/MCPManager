import '../core/json.dart';

enum AuditKind { toolCall, serverConnect, authorize, manage }

enum AuditStatus { success, error, denied }

enum AuditSource { workbench, operator, system }

/// One append-only record of something MCP Manager did. Arguments and results
/// are stored redacted and size-limited; the original values are never kept.
class AuditEvent {
  const AuditEvent({
    required this.id,
    required this.timestamp,
    required this.kind,
    required this.status,
    required this.source,
    required this.actor,
    this.serverId,
    this.serverName,
    this.toolName,
    this.durationMs,
    this.args,
    this.result,
    this.error,
    this.approval,
  });

  final String id;
  final DateTime timestamp;
  final AuditKind kind;
  final AuditStatus status;
  final AuditSource source;

  /// Who triggered it: `user` or `operator:<model>`.
  final String actor;
  final String? serverId;
  final String? serverName;
  final String? toolName;
  final int? durationMs;
  final String? args;
  final String? result;
  final String? error;

  /// `auto` (read-only tool), `user` (approved), `session` (allowed for the
  /// session) or `denied`. Null for actions that need no approval.
  final String? approval;

  Json toJson() => {
    'id': id,
    'ts': timestamp.toIso8601String(),
    'kind': kind.name,
    'status': status.name,
    'source': source.name,
    'actor': actor,
    if (serverId != null) 'serverId': serverId,
    if (serverName != null) 'serverName': serverName,
    if (toolName != null) 'tool': toolName,
    if (durationMs != null) 'durationMs': durationMs,
    if (args != null) 'args': args,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
    if (approval != null) 'approval': approval,
  };

  factory AuditEvent.fromJson(Json json) => AuditEvent(
    id: json['id'] as String,
    timestamp: DateTime.parse(json['ts'] as String),
    kind: AuditKind.values.byName(json['kind'] as String),
    status: AuditStatus.values.byName(json['status'] as String),
    source: AuditSource.values.byName(json['source'] as String),
    actor: json['actor'] as String? ?? 'user',
    serverId: json['serverId'] as String?,
    serverName: json['serverName'] as String?,
    toolName: json['tool'] as String?,
    durationMs: json['durationMs'] as int?,
    args: json['args'] as String?,
    result: json['result'] as String?,
    error: json['error'] as String?,
    approval: json['approval'] as String?,
  );

  String get title => switch (kind) {
    AuditKind.toolCall => '${serverName ?? '?'} · ${toolName ?? '?'}',
    AuditKind.serverConnect => 'Connect ${serverName ?? '?'}',
    AuditKind.authorize => 'Authorize ${serverName ?? '?'}',
    AuditKind.manage =>
      'Manage · ${toolName ?? '?'}${serverName == null ? '' : ' · $serverName'}',
  };
}
