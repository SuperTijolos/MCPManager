import 'package:mcp_core/mcp_core.dart';

/// The list entry of one conversation.
class ChatMeta {
  const ChatMeta({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.autoApprove = false,
    this.messageCount = 0,
  });

  final String id;
  final String ownerId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The Operator runs tool calls in this conversation without asking.
  final bool autoApprove;

  /// How many prompts the person has written in it.
  final int messageCount;

  Json toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'messageCount': messageCount,
    'autoApprove': autoApprove,
  };
}

/// What a conversation holds: the screen's items and the model's history, as
/// the dashboard writes them.
class ChatContent {
  const ChatContent({this.items = const [], this.history = const []});
  final List<Json> items;
  final List<Json> history;

  int get promptCount => items.where((i) => i['type'] == 'user').length;
}

class ChatDocument {
  const ChatDocument(this.meta, this.content);
  final ChatMeta meta;
  final ChatContent content;
}

/// Where conversations are kept. Everything is per owner; an id that belongs
/// to someone else is treated as if it did not exist.
abstract class ChatRepository {
  factory ChatRepository.memory() = MemoryChatRepository;

  /// Newest first.
  Future<List<ChatMeta>> list(String ownerId);

  Future<ChatDocument?> get(String id);

  /// Creates the conversation if [id] is new, or updates the given fields.
  /// Throws [ChatOwnerMismatch] if [id] belongs to someone else.
  Future<ChatMeta> save(
    String id,
    String ownerId,
    DateTime now, {
    String? title,
    bool? autoApprove,
    ChatContent? content,
  });

  Future<bool> delete(String id, String ownerId);

  /// Keeps the [keep] most recently updated conversations of [ownerId];
  /// returns the ids removed.
  Future<List<String>> prune(String ownerId, int keep);
}

class ChatOwnerMismatch implements Exception {}

class MemoryChatRepository implements ChatRepository {
  final _metas = <String, ChatMeta>{};
  final _contents = <String, ChatContent>{};

  @override
  Future<List<ChatMeta>> list(String ownerId) async =>
      [
        for (final m in _metas.values)
          if (m.ownerId == ownerId) m,
      ]..sort((a, b) {
        final byTime = b.updatedAt.compareTo(a.updatedAt);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });

  @override
  Future<ChatDocument?> get(String id) async {
    final meta = _metas[id];
    if (meta == null) return null;
    return ChatDocument(meta, _contents[id] ?? const ChatContent());
  }

  @override
  Future<ChatMeta> save(
    String id,
    String ownerId,
    DateTime now, {
    String? title,
    bool? autoApprove,
    ChatContent? content,
  }) async {
    final old = _metas[id];
    if (old != null && old.ownerId != ownerId) throw ChatOwnerMismatch();
    final meta = ChatMeta(
      id: id,
      ownerId: ownerId,
      title: title ?? old?.title ?? 'New conversation',
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
      autoApprove: autoApprove ?? old?.autoApprove ?? false,
      messageCount: content?.promptCount ?? old?.messageCount ?? 0,
    );
    _metas[id] = meta;
    if (content != null) _contents[id] = content;
    return meta;
  }

  @override
  Future<bool> delete(String id, String ownerId) async {
    final meta = _metas[id];
    if (meta == null || meta.ownerId != ownerId) return false;
    _metas.remove(id);
    _contents.remove(id);
    return true;
  }

  @override
  Future<List<String>> prune(String ownerId, int keep) async {
    final all = await list(ownerId);
    final drop = [for (final m in all.skip(keep)) m.id];
    for (final id in drop) {
      _metas.remove(id);
      _contents.remove(id);
    }
    return drop;
  }
}
