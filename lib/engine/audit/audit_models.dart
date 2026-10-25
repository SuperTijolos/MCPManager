import '../core/json.dart';

enum AuditKind { toolCall, serverConnect, authorize, manage }

enum AuditStatus { success, error, denied }

/// Where a call came from: the Tools page, the chat, the gateway itself, or an
/// MCP client that used a portal.
enum AuditSource { workbench, operator, system, portal }

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
    this.forwarded,
    this.context,
    this.result,
    this.error,
    this.approval,
    this.conversationId,
    this.portalSlug,
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

  /// What the caller sent, redacted.
  final String? args;

  /// What was actually forwarded to the server, when rules changed it.
  final String? forwarded;

  /// Audit-only values supplied by the model (for example a reason).
  final String? context;
  final String? result;
  final String? error;

  /// `auto` (read-only tool), `user` (approved), `session` (allowed for the
  /// session), `automatic` (the chat runs tools without asking) or `denied`. Null for actions that need no approval.
  final String? approval;

  /// The chat conversation that made the call, when one did.
  final String? conversationId;

  /// The portal an MCP client used, for calls that came through one.
  final String? portalSlug;

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
    if (forwarded != null) 'forwarded': forwarded,
    if (context != null) 'context': context,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
    if (approval != null) 'approval': approval,
    if (conversationId != null) 'conv': conversationId,
    if (portalSlug != null) 'portal': portalSlug,
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
    forwarded: json['forwarded'] as String?,
    context: json['context'] as String?,
    result: json['result'] as String?,
    error: json['error'] as String?,
    approval: json['approval'] as String?,
    conversationId: json['conv'] as String?,
    portalSlug: json['portal'] as String?,
  );

  /// An event as the server stores it.
  factory AuditEvent.fromServer(Json json) {
    final principal = ((json['principal'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final source = switch (json['source']) {
      'dashboard' => AuditSource.workbench,
      'chat' => AuditSource.operator,
      'system' => AuditSource.system,
      _ => AuditSource.portal,
    };
    return AuditEvent(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['ts'] as String).toLocal(),
      kind: AuditKind.values.byName(json['kind'] as String? ?? 'toolCall'),
      status: AuditStatus.values.byName(json['status'] as String? ?? 'error'),
      source: source,
      actor:
          json['actor'] as String? ??
          principal['name'] as String? ??
          (source == AuditSource.workbench ? 'user' : 'unknown'),
      serverId: json['serverId'] as String?,
      serverName: json['serverName'] as String?,
      toolName: json['tool'] as String? ?? json['exposedName'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      args: json['args'] as String?,
      forwarded: json['forwarded'] as String?,
      context: json['context'] as String?,
      result: json['result'] as String?,
      error: json['error'] as String?,
      approval: json['approval'] as String?,
      conversationId: json['conversationId'] as String?,
      portalSlug: json['portalSlug'] as String?,
    );
  }

  String get title => switch (kind) {
    AuditKind.toolCall => '${serverName ?? '?'} · ${toolName ?? '?'}',
    AuditKind.serverConnect => 'Connect ${serverName ?? '?'}',
    AuditKind.authorize => 'Authorize ${serverName ?? '?'}',
    AuditKind.manage =>
      'Manage · ${toolName ?? '?'}${serverName == null ? '' : ' · $serverName'}',
  };
}
