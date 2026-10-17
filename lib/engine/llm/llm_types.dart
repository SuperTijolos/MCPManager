import '../core/json.dart';

enum LlmRole { system, user, assistant, tool }

class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    this.arguments = const {},
  });

  final String id;
  final String name;
  final Json arguments;
}

class LlmMessage {
  const LlmMessage({
    required this.role,
    required this.content,
    this.thinking,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });

  const LlmMessage.system(String content)
    : this(role: LlmRole.system, content: content);
  const LlmMessage.user(String content)
    : this(role: LlmRole.user, content: content);
  const LlmMessage.assistant(
    String content, {
    String? thinking,
    List<LlmToolCall> toolCalls = const [],
  }) : this(
         role: LlmRole.assistant,
         content: content,
         thinking: thinking,
         toolCalls: toolCalls,
       );
  const LlmMessage.tool(
    String content, {
    required String toolCallId,
    required String toolName,
  }) : this(
         role: LlmRole.tool,
         content: content,
         toolCallId: toolCallId,
         toolName: toolName,
       );

  final LlmRole role;
  final String content;
  final String? thinking;
  final List<LlmToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;
}

class LlmToolSpec {
  const LlmToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON Schema for the arguments object.
  final Json parameters;
}

class LlmModel {
  const LlmModel(this.name, {this.supportsTools});

  final String name;

  /// Null when the provider cannot tell.
  final bool? supportsTools;
}

sealed class LlmEvent {
  const LlmEvent();
}

class LlmTextDelta extends LlmEvent {
  const LlmTextDelta(this.text);
  final String text;
}

class LlmThinkingDelta extends LlmEvent {
  const LlmThinkingDelta(this.text);
  final String text;
}

class LlmToolCallsEvent extends LlmEvent {
  const LlmToolCallsEvent(this.calls);
  final List<LlmToolCall> calls;
}

class LlmDone extends LlmEvent {
  const LlmDone({this.promptTokens, this.completionTokens});
  final int? promptTokens;
  final int? completionTokens;
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class LlmProvider {
  Future<List<LlmModel>> listModels();

  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools,
  });

  void close();
}
