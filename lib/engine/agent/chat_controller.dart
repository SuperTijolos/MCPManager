import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/json.dart';
import '../core/prefs.dart';
import '../llm/llm_settings.dart';
import '../llm/llm_types.dart';
import '../settings/app_settings.dart';
import 'chat_store.dart';
import 'agent_tool.dart';
import 'operator_agent.dart';
import 'tool_insight.dart';
import 'toolbox.dart';

const _maxStoredItems = 80;
const _maxStoredOutput = 4000;

sealed class ChatItem {
  const ChatItem(this.id);
  final String id;

  Json toJson();

  static ChatItem? fromJson(Json json) {
    try {
      final id = json['id'] as String;
      switch (json['type']) {
        case 'user':
          return UserItem(id, json['text'] as String);
        case 'assistant':
          return AssistantItem(
            id,
            text: json['text'] as String? ?? '',
            thinking: json['thinking'] as String? ?? '',
          );
        case 'error':
          return ErrorItem(id, json['message'] as String);
        case 'tool':
          // A call that was waiting or running when the page closed never
          // finished; show it as interrupted rather than pending forever.
          var status = ToolStatus.values.byName(json['status'] as String);
          var output = json['output'] as String?;
          if (status == ToolStatus.awaitingApproval ||
              status == ToolStatus.running) {
            status = ToolStatus.error;
            output = 'Interrupted: the page was closed before this finished.';
          }
          return ToolItem(
            id,
            callId: json['callId'] as String,
            name: json['name'] as String,
            label: json['label'] as String,
            args: ((json['args'] as Map?) ?? const {}).cast<String, dynamic>(),
            status: status,
            output: output,
            description: json['description'] as String?,
            summary: json['summary'] as String?,
            canAlwaysAllow: json['canAlwaysAllow'] as bool? ?? true,
          );
      }
    } catch (_) {
      // Skip entries from an incompatible version.
    }
    return null;
  }
}

class UserItem extends ChatItem {
  const UserItem(super.id, this.text);
  final String text;

  @override
  Json toJson() => {'type': 'user', 'id': id, 'text': text};
}

class AssistantItem extends ChatItem {
  const AssistantItem(super.id, {this.text = '', this.thinking = ''});
  final String text;
  final String thinking;

  AssistantItem copyWith({String? text, String? thinking}) => AssistantItem(
    id,
    text: text ?? this.text,
    thinking: thinking ?? this.thinking,
  );

  @override
  Json toJson() => {
    'type': 'assistant',
    'id': id,
    'text': text,
    'thinking': thinking,
  };
}

enum ToolStatus { awaitingApproval, running, done, error, denied }

class ToolItem extends ChatItem {
  const ToolItem(
    super.id, {
    required this.callId,
    required this.name,
    required this.label,
    required this.args,
    required this.status,
    this.output,
    this.description,
    this.summary,
    this.canAlwaysAllow = true,
  });

  final String callId;
  final String name;
  final String label;

  /// The arguments as shown to the user (secrets masked for sensitive tools).
  final Json args;
  final ToolStatus status;
  final String? output;
  final String? description;

  /// Plain-language line shown on the approval card, when the tool has one.
  final String? summary;
  final bool canAlwaysAllow;

  ToolItem copyWith({ToolStatus? status, String? output}) => ToolItem(
    id,
    callId: callId,
    name: name,
    label: label,
    args: args,
    status: status ?? this.status,
    output: output ?? this.output,
    description: description,
    summary: summary,
    canAlwaysAllow: canAlwaysAllow,
  );

  @override
  Json toJson() => {
    'type': 'tool',
    'id': id,
    'callId': callId,
    'name': name,
    'label': label,
    'args': args,
    'status': status.name,
    'output': output == null ? null : truncate(output!, _maxStoredOutput),
    'description': description,
    'summary': summary,
    'canAlwaysAllow': canAlwaysAllow,
  };
}

class ErrorItem extends ChatItem {
  const ErrorItem(super.id, this.message);
  final String message;

  @override
  Json toJson() => {'type': 'error', 'id': id, 'message': message};
}

class ChatState {
  const ChatState({
    this.items = const [],
    this.running = false,
    this.conversations = const [],
    this.activeId,
    this.autoApprove = false,
  });

  final List<ChatItem> items;
  final bool running;

  /// Saved conversations, most recently used first.
  final List<ConversationMeta> conversations;

  /// The open conversation; null until the first message of a new one.
  final String? activeId;

  /// Whether tool calls run without asking in the open conversation.
  final bool autoApprove;

  ChatState copyWith({
    List<ChatItem>? items,
    bool? running,
    List<ConversationMeta>? conversations,
    String? activeId,
    bool clearActive = false,
    bool? autoApprove,
  }) => ChatState(
    items: items ?? this.items,
    running: running ?? this.running,
    conversations: conversations ?? this.conversations,
    activeId: clearActive ? null : activeId ?? this.activeId,
    autoApprove: autoApprove ?? this.autoApprove,
  );
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

class ChatController extends Notifier<ChatState> {
  final _history = <LlmMessage>[];
  final _sessionAllowed = <String>{};
  final _pending = <String, Completer<ApprovalDecision>>{};
  bool _cancelled = false;
  int _runToken = 0;

  ChatStore get _store => ChatStore(ref.read(sharedPreferencesProvider));

  @override
  ChatState build() {
    ref.onDispose(() {
      _cancelled = true;
      _resolveAll(ApprovalDecision.deny);
    });
    final store = _store;
    final conversations = store.migrateLegacy(
      store.index(),
      () => newId('chat'),
    );
    final activeId = store.activeId();
    if (activeId != null && conversations.any((c) => c.id == activeId)) {
      return _load(activeId, conversations);
    }
    return ChatState(conversations: conversations);
  }

  ChatState _load(String id, List<ConversationMeta> conversations) {
    _history.clear();
    _sessionAllowed.clear();
    final stored = _store.load(id);
    if (stored == null) return ChatState(conversations: conversations);
    final items = <ChatItem>[
      for (final i in stored.items) ?ChatItem.fromJson(i),
    ];
    try {
      _history.addAll([for (final m in stored.history) LlmMessage.fromJson(m)]);
    } catch (_) {
      _history.clear();
    }
    // A run interrupted by closing the page can leave an assistant turn with
    // tool calls but no results; drop back to the last consistent point.
    while (_history.isNotEmpty) {
      final last = _history.last;
      final consistent =
          last.role == LlmRole.user ||
          (last.role == LlmRole.assistant && last.toolCalls.isEmpty);
      if (consistent) break;
      _history.removeLast();
    }
    final meta = conversations.where((c) => c.id == id).firstOrNull;
    return ChatState(
      items: items,
      conversations: conversations,
      activeId: id,
      autoApprove: meta?.autoApprove ?? false,
    );
  }

  /// Saves the open conversation and updates the history list.
  void _persist() {
    if (state.items.isEmpty) return;
    final store = _store;
    final id = state.activeId ?? newId('chat');
    final items = state.items.length > _maxStoredItems
        ? state.items.sublist(state.items.length - _maxStoredItems)
        : state.items;
    // Keep the model history to a window that starts at a user message, so it
    // never begins with an orphaned tool result.
    var history = _history.length > 60
        ? _history.sublist(_history.length - 60)
        : List.of(_history);
    while (history.isNotEmpty && history.first.role != LlmRole.user) {
      history.removeAt(0);
    }
    store.save(
      id,
      StoredConversation(
        items: [for (final i in items) i.toJson()],
        history: [for (final m in history) m.toJson()],
      ),
    );

    final now = DateTime.now();
    final prompts = state.items.whereType<UserItem>().toList();
    final existing = state.conversations.where((c) => c.id == id).firstOrNull;
    final meta =
        (existing ??
                ConversationMeta(
                  id: id,
                  title: titleFromPrompt(
                    prompts.isEmpty ? '' : prompts.first.text,
                  ),
                  createdAt: now,
                  updatedAt: now,
                  autoApprove: state.autoApprove,
                ))
            .copyWith(
              updatedAt: now,
              messageCount: prompts.length,
              autoApprove: state.autoApprove,
            );
    var list = [meta, ...state.conversations.where((c) => c.id != id)];
    // Keep the list bounded, dropping the least recently used conversations.
    while (list.length > maxConversations) {
      store.delete(list.removeLast().id);
    }
    store.saveIndex(list);
    store.setActive(id);
    state = state.copyWith(conversations: list, activeId: id);
  }

  /// Starts a fresh, empty conversation. The current one stays in the history.
  /// The new one keeps the approval mode you had selected, unless told otherwise.
  void newConversation({bool? autoApprove}) {
    if (state.running) stop();
    _runToken++;
    _history.clear();
    _sessionAllowed.clear();
    _store.setActive(null);
    state = ChatState(
      conversations: state.conversations,
      autoApprove: autoApprove ?? state.autoApprove,
    );
  }

  /// Switches the open conversation between asking before tool calls and
  /// running them automatically. The choice is saved with the conversation.
  void setAutoApprove(bool value) {
    if (value == state.autoApprove) return;
    state = state.copyWith(autoApprove: value);
    final id = state.activeId;
    if (id == null) return;
    final list = [
      for (final c in state.conversations)
        if (c.id == id) c.copyWith(autoApprove: value) else c,
    ];
    _store.saveIndex(list);
    state = state.copyWith(conversations: list);
  }

  /// Switches to a saved conversation, stopping any run in progress.
  void open(String id) {
    if (id == state.activeId) return;
    if (!state.conversations.any((c) => c.id == id)) return;
    if (state.running) stop();
    _runToken++;
    _store.setActive(id);
    state = _load(id, state.conversations);
  }

  void rename(String id, String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    final list = [
      for (final c in state.conversations)
        if (c.id == id) c.copyWith(title: t) else c,
    ];
    _store.saveIndex(list);
    state = state.copyWith(conversations: list);
  }

  void delete(String id) {
    final wasActive = id == state.activeId;
    _store.delete(id);
    final list = [
      for (final c in state.conversations)
        if (c.id != id) c,
    ];
    _store.saveIndex(list);
    if (wasActive) {
      if (state.running) stop();
      _runToken++;
      _history.clear();
      _sessionAllowed.clear();
      _store.setActive(null);
      state = ChatState(conversations: list);
    } else {
      state = state.copyWith(conversations: list);
    }
  }

  /// Deletes every saved conversation.
  void deleteAll() {
    for (final c in state.conversations) {
      _store.delete(c.id);
    }
    _store.saveIndex(const []);
    newConversation();
    state = const ChatState();
  }

  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || state.running) return;

    final settings = ref.read(llmSettingsProvider);
    final config = settings.activeProvider;
    final model = settings.activeModel;
    if (config == null || model == null || model.isEmpty) {
      _append(
        ErrorItem(
          newId('err'),
          'Choose a provider and model in Settings first.',
        ),
      );
      return;
    }

    final token = ++_runToken;
    _cancelled = false;
    _history.add(LlmMessage.user(prompt));
    // On cancel/error, drop the half-finished exchange but keep the prompt so
    // the model's context matches what the user sees.
    final mark = _history.length;
    state = state.copyWith(
      items: [...state.items, UserItem(newId('u'), prompt)],
      running: true,
    );
    // Save right away so the conversation shows up in the history even if
    // the page is closed before the model answers.
    _persist();
    _append(AssistantItem(newId('a')));

    final provider = ref.read(llmProviderFactoryProvider)(config);
    final toolbox = buildToolboxWithInsight(ref);
    final agent = OperatorAgent(
      provider: provider,
      model: model,
      tools: toolbox.tools,
      capabilityMap: buildCapabilityMap(toolbox.index),
      advisor: ToolAdvisor(toolbox.index),
      requestApproval: _askApproval,
      isCancelled: () => _cancelled || token != _runToken,
      sessionAllowed: _sessionAllowed,
      autoApprove: state.autoApprove,
      maxSteps: ref.read(appSettingsProvider).maxSteps,
      extraInstructions: ref.read(appSettingsProvider).extraInstructions,
    );

    try {
      await agent.run(_history, (event) => _onEvent(token, event));
      if (_cancelled) _history.length = mark;
    } catch (e) {
      _history.length = mark;
      if (token == _runToken) _append(ErrorItem(newId('err'), '$e'));
    } finally {
      provider.close();
      if (token == _runToken) {
        _dropEmptyAssistant();
        state = state.copyWith(running: false);
        _persist();
      }
    }
  }

  void stop() {
    if (!state.running) return;
    _cancelled = true;
    _resolveAll(ApprovalDecision.deny);
  }

  /// Same as [newConversation]; kept for the "new conversation" button.
  void clear() => newConversation();

  void decide(String callId, ApprovalDecision decision) {
    final completer = _pending.remove(callId);
    if (completer == null) return;
    if (decision != ApprovalDecision.deny) {
      _updateTool(callId, (t) => t.copyWith(status: ToolStatus.running));
    }
    completer.complete(decision);
  }

  Future<ApprovalDecision> _askApproval(LlmToolCall call, AgentTool tool) {
    final completer = Completer<ApprovalDecision>();
    _pending[call.id] = completer;
    return completer.future;
  }

  void _resolveAll(ApprovalDecision decision) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(decision);
    }
    _pending.clear();
  }

  void _onEvent(int token, AgentEvent event) {
    if (token != _runToken) return;
    switch (event) {
      case AgentTextDelta(:final text):
        _updateLastAssistant((a) => a.copyWith(text: a.text + text));
      case AgentThinkingDelta(:final text):
        _updateLastAssistant((a) => a.copyWith(thinking: a.thinking + text));
      case AgentMessageStart():
        _dropEmptyAssistant();
        _append(AssistantItem(newId('a')));
      case AgentToolRequested(:final call, :final tool, :final needsApproval):
        _dropEmptyAssistant();
        _append(
          ToolItem(
            newId('t'),
            callId: call.id,
            name: call.name,
            label: tool?.label ?? call.name,
            args: tool?.displayArgs(call.arguments) ?? call.arguments,
            description: tool?.description,
            summary: tool?.summarize(call.arguments),
            canAlwaysAllow: tool?.canAlwaysAllow ?? true,
            status: needsApproval
                ? ToolStatus.awaitingApproval
                : ToolStatus.running,
          ),
        );
      case AgentToolFinished(:final call, :final outcome, :final output):
        _updateTool(
          call.id,
          (t) => t.copyWith(
            status: switch (outcome) {
              ToolOutcome.success => ToolStatus.done,
              ToolOutcome.denied => ToolStatus.denied,
              _ => ToolStatus.error,
            },
            output: output,
          ),
        );
        _append(AssistantItem(newId('a')));
      case AgentUsage():
        break;
    }
  }

  void _append(ChatItem item) =>
      state = state.copyWith(items: [...state.items, item]);

  void _updateLastAssistant(AssistantItem Function(AssistantItem) update) {
    final items = [...state.items];
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is AssistantItem) {
        items[i] = update(item);
        state = state.copyWith(items: items);
        return;
      }
    }
  }

  void _updateTool(String callId, ToolItem Function(ToolItem) update) {
    final items = [...state.items];
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is ToolItem && item.callId == callId) {
        items[i] = update(item);
        state = state.copyWith(items: items);
        return;
      }
    }
  }

  void _dropEmptyAssistant() {
    final last = state.items.isEmpty ? null : state.items.last;
    if (last is AssistantItem && last.text.isEmpty && last.thinking.isEmpty) {
      state = state.copyWith(items: [...state.items]..removeLast());
    }
  }
}
