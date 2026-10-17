import '../core/json.dart';

class ToolRunContext {
  const ToolRunContext({required this.actor, this.approval});

  /// `operator:<model>`.
  final String actor;

  /// How the call was authorised: `auto`, `user` or `session`.
  final String? approval;
}

class AgentToolResult {
  const AgentToolResult(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

/// A capability the operator model may invoke. Wraps either an MCP tool from a
/// managed server or a built-in platform tool.
abstract class AgentTool {
  /// Name shown to the model; matches `^[a-zA-Z0-9_-]{1,64}$`.
  String get name;
  String get description;
  Json get parameters;

  /// Human-friendly label for the UI, e.g. `weather · get_forecast`.
  String get label;

  /// Whether a human must approve each call. Defaults to true; only tools
  /// that are known to be read-only opt out.
  bool get requiresApproval;

  Future<AgentToolResult> run(Json args, ToolRunContext context);

  /// Called when a human refused this call, so it can be audited.
  void onDenied(Json args, ToolRunContext context) {}
}
