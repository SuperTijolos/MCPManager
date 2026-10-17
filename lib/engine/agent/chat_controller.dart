import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/json.dart';
import '../llm/llm_settings.dart';
import '../llm/llm_types.dart';
import 'agent_tool.dart';
import 'operator_agent.dart';
import 'toolbox.dart';

sealed class ChatItem {
  const ChatItem(this.id);
  final String id;
}

class UserItem extends ChatItem {
  const UserItem(super.id, this.text);
  final String text;
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
  });

  final String callId;
  final String name;
  final String label;
  final Json args;
  final ToolStatus status;
  final String? output;
  final String? description;

  ToolItem copyWith({ToolStatus? status, String? output}) => ToolItem(
    id,
    callId: callId,
    name: name,
    label: label,
    args: args,
    status: status ?? this.status,
    output: output ?? this.output,
    description: description,
  );
}

class ErrorItem extends ChatItem {
  const ErrorItem(super.id, this.message);
  final String message;
}

class ChatState {
  const ChatState({this.items = const [], this.running = false});
  final List<ChatItem> items;
  final bool running;

  ChatState copyWith({List<ChatItem>? items, bool? running}) =>
      ChatState(items: items ?? this.items, running: running ?? this.running);
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

  @override
  ChatState build() {
    ref.onDispose(() {
      _cancelled = true;
      _resolveAll(ApprovalDecision.deny);
    });
    return const ChatState();
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
    _append(AssistantItem(newId('a')));

    final provider = ref.read(llmProviderFactoryProvider)(config);
    final agent = OperatorAgent(
      provider: provider,
      model: model,
      tools: buildToolbox(ref),
      requestApproval: _askApproval,
      isCancelled: () => _cancelled || token != _runToken,
      sessionAllowed: _sessionAllowed,
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
      }
    }
  }

  void stop() {
    if (!state.running) return;
    _cancelled = true;
    _resolveAll(ApprovalDecision.deny);
  }

  void clear() {
    stop();
    _runToken++;
    _history.clear();
    _sessionAllowed.clear();
    state = const ChatState();
  }

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
            args: call.arguments,
            description: tool?.description,
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
