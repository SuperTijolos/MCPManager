import 'package:shared_preferences/shared_preferences.dart';

import '../core/json.dart';
import '../core/prefs.dart';

const _indexKey = 'mcpm.chats.index.v1';
const _activeKey = 'mcpm.chats.active.v1';
const _legacyKey = 'mcpm.chat.v1';
String _contentKey(String id) => 'mcpm.chat.$id.v1';

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

/// Persistence for the conversation list and each conversation's content. Each
/// conversation lives under its own key so saving one never rewrites the rest.
class ChatStore {
  ChatStore(this._prefs);

  final SharedPreferences _prefs;

  List<ConversationMeta> index() {
    final raw = readJson(_prefs, _indexKey);
    if (raw is! List) return const [];
    final list = <ConversationMeta>[];
    for (final item in raw) {
      try {
        list.add(
          ConversationMeta.fromJson((item as Map).cast<String, dynamic>()),
        );
      } catch (_) {
        // Skip entries from an incompatible version.
      }
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  void saveIndex(List<ConversationMeta> list) {
    writeJson(_prefs, _indexKey, [for (final m in list) m.toJson()]);
  }

  String? activeId() => _prefs.getString(_activeKey);

  void setActive(String? id) {
    if (id == null) {
      _prefs.remove(_activeKey);
    } else {
      _prefs.setString(_activeKey, id);
    }
  }

  StoredConversation? load(String id) {
    final raw = readJson(_prefs, _contentKey(id));
    if (raw is! Map) return null;
    List<Json> list(Object? v) => [
      for (final e in (v as List?) ?? const [])
        if (e is Map) e.cast<String, dynamic>(),
    ];
    return StoredConversation(
      items: list(raw['items']),
      history: list(raw['history']),
    );
  }

  void save(String id, StoredConversation content) {
    writeJson(_prefs, _contentKey(id), {
      'items': content.items,
      'history': content.history,
    });
  }

  void delete(String id) => _prefs.remove(_contentKey(id));

  /// Moves the single conversation of the first version (`mcpm.chat.v1`) into
  /// the list, once.
  List<ConversationMeta> migrateLegacy(
    List<ConversationMeta> current,
    String Function() newId,
  ) {
    final raw = readJson(_prefs, _legacyKey);
    if (raw is! Map) return current;
    _prefs.remove(_legacyKey);
    final items = ((raw['items'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    if (items.isEmpty) return current;
    final firstUser = items.firstWhere(
      (i) => i['type'] == 'user',
      orElse: () => const {},
    );
    final id = newId();
    final now = DateTime.now();
    save(
      id,
      StoredConversation(
        items: [for (final i in items) i.cast<String, dynamic>()],
        history: [
          for (final m in (raw['history'] as List?) ?? const [])
            if (m is Map) m.cast<String, dynamic>(),
        ],
      ),
    );
    final meta = ConversationMeta(
      id: id,
      title: titleFromPrompt('${firstUser['text'] ?? ''}'),
      createdAt: now,
      updatedAt: now,
      messageCount: items.where((i) => i['type'] == 'user').length,
    );
    final next = [meta, ...current];
    saveIndex(next);
    return next;
  }
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
