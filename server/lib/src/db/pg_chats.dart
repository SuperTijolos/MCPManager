import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';
import 'package:postgres/postgres.dart';

import '../chats.dart';
import 'database.dart';

/// Conversations in the `chats` and `chat_content` tables.
class PgChatRepository implements ChatRepository {
  PgChatRepository(this.db);

  final Database db;

  @override
  Future<List<ChatMeta>> list(String ownerId) async {
    final rows = await db.pool.execute(
      Sql.named(
        'select * from chats where owner_id = @owner '
        'order by updated_at desc, id desc',
      ),
      parameters: {'owner': ownerId},
    );
    return [for (final r in rows) _meta(r.toColumnMap())];
  }

  @override
  Future<ChatDocument?> get(String id) async {
    final rows = await db.pool.execute(
      Sql.named('''
        select c.*, k.items, k.history
        from chats c left join chat_content k on k.chat_id = c.id
        where c.id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    final r = rows.first.toColumnMap();
    return ChatDocument(
      _meta(r),
      ChatContent(items: _objects(r['items']), history: _objects(r['history'])),
    );
  }

  @override
  Future<ChatMeta> save(
    String id,
    String ownerId,
    DateTime now, {
    String? title,
    bool? autoApprove,
    ChatContent? content,
  }) => db.pool.runTx((tx) async {
    final existing = await tx.execute(
      Sql.named('select owner_id from chats where id = @id for update'),
      parameters: {'id': id},
    );
    if (existing.isEmpty) {
      await tx.execute(
        Sql.named('''
          insert into chats (id, owner_id, title, auto_approve, message_count,
                             created_at, updated_at)
          values (@id, @owner, @title, @auto, @count, @now, @now)
        '''),
        parameters: {
          'id': id,
          'owner': ownerId,
          'title': title ?? 'New conversation',
          'auto': autoApprove ?? false,
          'count': content?.promptCount ?? 0,
          'now': now.toUtc(),
        },
      );
    } else {
      if (existing.first[0] != ownerId) throw ChatOwnerMismatch();
      await tx.execute(
        Sql.named('''
          update chats set
            title = coalesce(@title, title),
            auto_approve = coalesce(@auto, auto_approve),
            message_count = coalesce(@count, message_count),
            updated_at = @now
          where id = @id
        '''),
        parameters: {
          'id': id,
          'title': title,
          'auto': autoApprove,
          'count': content?.promptCount,
          'now': now.toUtc(),
        },
      );
    }
    if (content != null) {
      await tx.execute(
        Sql.named('''
          insert into chat_content (chat_id, items, history)
          values (@id, @items:jsonb, @history:jsonb)
          on conflict (chat_id) do update
            set items = excluded.items, history = excluded.history
        '''),
        parameters: {
          'id': id,
          'items': content.items,
          'history': content.history,
        },
      );
    }
    final row = await tx.execute(
      Sql.named('select * from chats where id = @id'),
      parameters: {'id': id},
    );
    return _meta(row.first.toColumnMap());
  });

  @override
  Future<bool> delete(String id, String ownerId) async {
    final r = await db.pool.execute(
      Sql.named('delete from chats where id = @id and owner_id = @owner'),
      parameters: {'id': id, 'owner': ownerId},
    );
    return r.affectedRows > 0;
  }

  @override
  Future<List<String>> prune(String ownerId, int keep) async {
    final rows = await db.pool.execute(
      Sql.named('''
        delete from chats where id in (
          select id from chats where owner_id = @owner
          order by updated_at desc, id desc offset @keep
        ) returning id
      '''),
      parameters: {'owner': ownerId, 'keep': keep},
    );
    return [for (final r in rows) r[0] as String];
  }
}

ChatMeta _meta(Map<String, Object?> r) => ChatMeta(
  id: r['id'] as String,
  ownerId: r['owner_id'] as String,
  title: r['title'] as String,
  createdAt: r['created_at'] as DateTime,
  updatedAt: r['updated_at'] as DateTime,
  autoApprove: r['auto_approve'] as bool,
  messageCount: r['message_count'] as int,
);

List<Json> _objects(Object? v) {
  Object? d = v;
  if (d is UndecodedBytes) d = jsonDecode(d.asString);
  if (d is String) d = jsonDecode(d);
  return [
    for (final e in (d as List?) ?? const [])
      if (e is Map) e.cast<String, dynamic>(),
  ];
}
