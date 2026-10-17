import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

const appName = 'MCP Manager';
const appVersion = '1.0.0';
const appRepoUrl = 'https://github.com/SuperTijolos/MCPManager';
const mcpSpecUrl = 'https://modelcontextprotocol.io';
const ollamaUrl = 'https://ollama.com';

class Contributor {
  const Contributor({
    required this.login,
    required this.name,
    required this.role,
  });

  /// GitHub username.
  final String login;
  final String name;
  final String role;

  String get profileUrl => 'https://github.com/$login';
  String get avatarUrl => 'https://github.com/$login.png?size=160';

  /// One or two capitals for the avatar fallback ("tr_18" gives "T").
  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'[\s_.-]+'))
        .where((p) => RegExp(r'^[A-Za-z]').hasMatch(p));
    final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? login[0].toUpperCase() : letters;
  }
}

/// The people behind the project, in the order they are shown.
const contributors = [
  Contributor(
    login: 'GuikiPT',
    name: 'GuikiPT',
    role: 'Flutter rewrite · project owner',
  ),
  Contributor(login: 'AjaxR0', name: 'Ajax', role: 'Co-author'),
  Contributor(login: 'TeeAr18', name: 'tr_18', role: 'Co-author'),
];

/// Opens a link in the browser. Overridden in tests to record the request.
final openUrlProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);
