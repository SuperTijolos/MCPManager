import '../../../engine/core/json.dart';

/// Sent with the navigation to `/mcp-tools` (not in the URL, so arguments
/// never end up in browser history): open this tool, and optionally start the
/// Test tab with these arguments.
class ToolFocus {
  const ToolFocus(this.key, {this.args});

  /// `serverId/toolName`, as `toolKey` builds it.
  final String key;
  final Json? args;
}
