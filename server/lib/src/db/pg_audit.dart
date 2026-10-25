import 'dart:async';

import 'package:postgres/postgres.dart';

import '../audit.dart';
import 'database.dart';

/// The audit log in the `audit_events` table. The dashboard watches that table
/// over Realtime, so a call shows up there as it happens.
class PgAuditLog implements GatewayAuditLog {
  PgAuditLog(this.db);

  final Database db;
  Future<void> _queue = Future.value();

  @override
  Future<void> record(GatewayAuditEvent e) {
    _queue = _queue.then((_) async {
      try {
        await db.pool.execute(
          Sql.named('''
            insert into audit_events (
              id, ts, source, portal_id, portal_slug, principal, status,
              server_id, server_name, tool, exposed_name, duration_ms,
              args, forwarded, context, result, error, rules, conversation_id,
              kind, actor, approval
            ) values (
              @id:text, @ts:timestamptz, @source:text, @portal_id:text,
              @portal_slug:text, @principal:jsonb, @status:text,
              @server_id:text, @server_name:text, @tool:text,
              @exposed_name:text, @duration_ms:int4, @args:text,
              @forwarded:text, @context:text, @result:text, @error:text,
              @rules:_text, @conversation_id:text,
              @kind:text, @actor:text, @approval:text
            ) on conflict (id) do nothing
          '''),
          parameters: {
            'id': e.id,
            'ts': e.timestamp.toUtc(),
            'source': e.source,
            'portal_id': e.portalId,
            'portal_slug': e.portalSlug,
            'principal': e.principal,
            'status': e.status,
            'server_id': e.serverId,
            'server_name': e.serverName,
            'tool': e.tool,
            'exposed_name': e.exposedName,
            'duration_ms': e.durationMs,
            'args': e.args,
            'forwarded': e.forwarded,
            'context': e.context,
            'result': e.result,
            'error': e.error,
            'rules': e.rules,
            'conversation_id': e.conversationId,
            'kind': e.kind,
            'actor': e.actor,
            'approval': e.approval,
          },
        );
      } catch (_) {
        // Losing a log line must never fail the call that was just served.
      }
    });
    return _queue;
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
    final q = query?.trim();
    final like = q == null || q.isEmpty
        ? null
        : '%${q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final rows = await db.pool.execute(
      Sql.named('''
        select * from audit_events
        where (@portal:text is null or portal_id = @portal)
          and (@status:text is null or status = @status)
          and (@source:text is null or source = @source)
          and (@conversation:text is null or conversation_id = @conversation)
          and (@like:text is null or concat_ws(' ', tool, exposed_name,
               server_name, error, args, result) ilike @like)
        order by ts desc, id desc
        limit @limit:int4
      '''),
      parameters: {
        'portal': portalId,
        'status': status,
        'source': source,
        'conversation': conversationId,
        'like': like,
        'limit': limit,
      },
    );
    return [for (final r in rows) _fromRow(r.toColumnMap())];
  }

  @override
  Future<int> delete({
    List<String>? ids,
    DateTime? before,
    bool all = false,
  }) async {
    await _queue;
    final r = await db.pool.execute(
      Sql.named('''
        delete from audit_events
        where @all:boolean
           or (@ids:_text is not null and id = any(@ids:_text))
           or (@before:timestamptz is not null and ts < @before:timestamptz)
      '''),
      parameters: {'all': all, 'ids': ids, 'before': before?.toUtc()},
    );
    return r.affectedRows;
  }

  @override
  Future<void> flush() => _queue;
}

GatewayAuditEvent _fromRow(Map<String, Object?> r) => GatewayAuditEvent(
  id: r['id'] as String,
  timestamp: r['ts'] as DateTime,
  source: r['source'] as String,
  portalId: r['portal_id'] as String?,
  portalSlug: r['portal_slug'] as String?,
  principal: ((r['principal'] as Map?) ?? const {}).cast<String, dynamic>(),
  status: r['status'] as String,
  serverId: r['server_id'] as String?,
  serverName: r['server_name'] as String?,
  tool: r['tool'] as String?,
  exposedName: r['exposed_name'] as String?,
  durationMs: r['duration_ms'] as int?,
  args: r['args'] as String?,
  forwarded: r['forwarded'] as String?,
  context: r['context'] as String?,
  result: r['result'] as String?,
  error: r['error'] as String?,
  rules: [for (final x in (r['rules'] as List?) ?? const []) '$x'],
  conversationId: r['conversation_id'] as String?,
  kind: r['kind'] as String,
  actor: r['actor'] as String?,
  approval: r['approval'] as String?,
);
