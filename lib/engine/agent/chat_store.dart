import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/json.dart';
import '../core/prefs.dart';
import '../server/server_client.dart';
import '../server/session.dart';

const _activeKey = 'mcpm.chats.active.v1';

/// How many conversations are kept; the oldest are dropped beyond this.
const maxConversations = 40;

/// What the history list shows for one conversation.
class ConversationMeta {
  const ConversationMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.autoApprove = false,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Number of things you said (prompts), for a quick sense of size.
  final int messageCount;

  /// When true, the Operator runs tool calls in this conversation without
  /// asking. Off by default; each conversation keeps its own choice.
  final bool autoApprove;

  ConversationMeta copyWith({
    String? title,
    DateTime? updatedAt,
    int? messageCount,
    bool? autoApprove,
  }) => ConversationMeta(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    messageCount: messageCount ?? this.messageCount,
    autoApprove: autoApprove ?? this.autoApprove,
  );

  Json toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messageCount': messageCount,
    'autoApprove': autoApprove,
  };

  factory ConversationMeta.fromJson(Json json) => ConversationMeta(
    id: json['id'] as String,
    title: json['title'] as String? ?? 'Conversation',
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    messageCount: json['messageCount'] as int? ?? 0,
    autoApprove: json['autoApprove'] as bool? ?? false,
  );
}

/// The stored body of a conversation: what the UI shows and what the model
/// remembers, as plain JSON.
class StoredConversation {
  const StoredConversation({this.items = const [], this.history = const []});
  final List<Json> items;
  final List<Json> history;
}

String titleFromPrompt(String prompt) {
  final line = prompt.trim().split('\n').first.trim();
  if (line.isEmpty) return 'New conversation';
  return line.length > 48 ? '${line.substring(0, 48).trimRight()}…' : line;
}

final chatStoreProvider = Provider<ChatStore>((ref) {
  final store = ChatStore(
    ref.watch(serverClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
  ref.onDispose(store.dispose);
  return store;
});

/// The conversation list and each conversation's content, kept on the server
/// (private to the signed-in person). Reads come from a local copy so the chat
/// stays quick; writes are queued and sent in order. Which conversation is
/// open is a local preference.
class ChatStore {
  ChatStore(this._client, this._prefs);

  final ServerClient? _client;
  final SharedPreferences _prefs;

  var _index = <ConversationMeta>[];
  final _content = <String, StoredConversation>{};
  Future<void> _queue = Future.value();
  var _pending = 0;
  var _disposed = false;

  /// Whether writes are still on their way to the server.
  bool get busy => _pending > 0;

  /// Completes when every write so far has reached the server.
  Future<void> get flushed => _queue;

  /// Loads the list from the server (and replaces the local copy).
  Future<List<ConversationMeta>> loadIndex() async {
    final client = _client;
    if (client == null) return _index;
    try {
      final list = await client.getList('/api/chats');
      if (_disposed) return _index;
      _index = [for (final j in list) ?_meta(j)]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } on ServerException {
      // Keep the copy we have.
    }
    return _index;
  }

  ConversationMeta? _meta(Json j) {
    try {
      return ConversationMeta.fromJson({
        ...j,
        'createdAt': j['createdAt'],
        'updatedAt': j['updatedAt'],
      });
    } catch (_) {
      return null;
    }
  }

  List<ConversationMeta> index() => List.of(_index);

  /// Fetches one conversation's content from the server into the local copy.
  Future<StoredConversation?> fetch(String id) async {
    final cached = _content[id];
    if (cached != null) return cached;
    final client = _client;
    if (client == null) return null;
    try {
      final j = await client.getMap('/api/chats/$id');
      List<Json> list(Object? v) => [
        for (final e in (v as List?) ?? const [])
          if (e is Map) e.cast<String, dynamic>(),
      ];
      final stored = StoredConversation(
        items: list(j['items']),
        history: list(j['history']),
      );
      _content[id] = stored;
      return stored;
    } on ServerException {
      return null;
    }
  }

  String? activeId() => _prefs.getString(_activeKey);

  void setActive(String? id) {
    if (id == null) {
      _prefs.remove(_activeKey);
    } else {
      _prefs.setString(_activeKey, id);
    }
  }

  /// The content already fetched or saved here, if any.
  StoredConversation? load(String id) => _content[id];

  void save(String id, StoredConversation content) {
    _content[id] = content;
    _enqueue(
      () => _client?.putMap('/api/chats/$id', {
        'items': content.items,
        'history': content.history,
      }),
    );
  }

  /// Records the list after a change: renames, approval mode, and new
  /// conversations get their title on the server.
  void saveIndex(List<ConversationMeta> list) {
    final before = {for (final m in _index) m.id: m};
    for (final m in list) {
      final old = before[m.id];
      if (old == null ||
          old.title != m.title ||
          old.autoApprove != m.autoApprove) {
        _enqueue(
          () => _client?.putMap('/api/chats/${m.id}', {
            'title': m.title,
            'autoApprove': m.autoApprove,
          }),
        );
      }
    }
    _index = List.of(list);
  }

  void delete(String id) {
    _content.remove(id);
    _enqueue(() => _client?.delete('/api/chats/$id'));
  }

  void _enqueue(Future<Object?>? Function() send) {
    if (_client == null) return;
    _pending++;
    _queue = _queue.then((_) async {
      try {
        await send();
      } on ServerException {
        // A write that fails is retried by the next save of that conversation.
      } finally {
        _pending--;
      }
    });
  }

  void dispose() => _disposed = true;
}

/// Which heading a conversation sits under in the history list.
String historyGroup(DateTime updated, DateTime now) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  final days = day(now).difference(day(updated)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'Previous 7 days';
  if (days < 30) return 'Previous 30 days';
  return 'Older';
}
