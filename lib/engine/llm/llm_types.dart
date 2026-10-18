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

  Json toJson() => {'id': id, 'name': name, 'arguments': arguments};

  factory LlmToolCall.fromJson(Json json) => LlmToolCall(
    id: json['id'] as String,
    name: json['name'] as String,
    arguments: ((json['arguments'] as Map?) ?? const {})
        .cast<String, dynamic>(),
  );
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

  /// The same message with other text and/or without its reasoning.
  LlmMessage copyWith({String? content, bool dropThinking = false}) =>
      LlmMessage(
        role: role,
        content: content ?? this.content,
        thinking: dropThinking ? null : thinking,
        toolCalls: toolCalls,
        toolCallId: toolCallId,
        toolName: toolName,
      );

  Json toJson() => {
    'role': role.name,
    'content': content,
    'thinking': ?thinking,
    if (toolCalls.isNotEmpty)
      'toolCalls': [for (final c in toolCalls) c.toJson()],
    'toolCallId': ?toolCallId,
    'toolName': ?toolName,
  };

  factory LlmMessage.fromJson(Json json) => LlmMessage(
    role: LlmRole.values.byName(json['role'] as String),
    content: json['content'] as String? ?? '',
    thinking: json['thinking'] as String?,
    toolCalls: [
      for (final c in (json['toolCalls'] as List?) ?? const [])
        LlmToolCall.fromJson((c as Map).cast<String, dynamic>()),
    ],
    toolCallId: json['toolCallId'] as String?,
    toolName: json['toolName'] as String?,
  );
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
