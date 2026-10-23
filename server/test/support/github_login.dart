import 'package:http/http.dart' as http;

import 'fake_github.dart';
import 'harness.dart';

extension MemberSignIn on Harness {
  /// Signs [user] in through [github] like a browser would; returns the
  /// session token.
  Future<String> signInAs(FakeGitHub github, GhUser user) async {
    Future<http.Response> get(String path, [Map<String, String>? h]) async {
      final r = http.Request('GET', Uri.parse('$base$path'))
        ..followRedirects = false
        ..headers.addAll(h ?? {});
      return http.Response.fromStream(await client.send(r));
    }

    final code = github.codeFor(user);
    final start = await get('/auth/github');
    final state = Uri.parse(
      start.headers['location']!,
    ).queryParameters['state']!;
    final done = await get('/auth/github/callback?code=$code&state=$state', {
      'cookie': 'mcp_login=$state',
    });
    return RegExp(
      'mcp_session=([^;,]+)',
    ).firstMatch(done.headers['set-cookie']!)!.group(1)!;
  }
}
