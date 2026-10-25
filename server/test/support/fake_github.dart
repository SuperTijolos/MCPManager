import 'dart:convert';
import 'dart:io';

class GhUser {
  GhUser(
    this.id,
    this.login, {
    this.name,
    this.orgs = const [],
    this.emails = const [],
  });
  final int id;
  final String login;
  final String? name;
  final List<String> orgs;

  /// `(address, verified)` pairs, as `/user/emails` lists them.
  final List<(String, bool)> emails;
}

/// Just enough of GitHub for the sign-in: the code exchange, `/user`,
/// `/user/orgs` and `/user/emails`.
class FakeGitHub {
  FakeGitHub._(this._server);

  final HttpServer _server;
  final _codes = <String, GhUser>{};
  var _next = 0;

  /// Make the next calls fail like GitHub would.
  bool rejectCodes = false;
  int orgsStatus = 200;

  /// What the app sent, in order, as `METHOD path`.
  final requests = <String>[];
  final secretsSeen = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeGitHub> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gh = FakeGitHub._(server);
    server.listen(gh._handle);
    return gh;
  }

  /// A code GitHub would hand back after [user] approves the app.
  String codeFor(GhUser user) {
    final code = 'code-${_next++}';
    _codes[code] = user;
    _known.add(user);
    return code;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add('${request.method} ${request.uri.path}');
    final body = await utf8.decoder.bind(request).join();
    void send(int status, Object json) {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(json));
      request.response.close();
    }

    if (request.uri.path == '/login/oauth/access_token') {
      final form = Uri.splitQueryString(body);
      secretsSeen.add(form['client_secret'] ?? '');
      final user = _codes.remove(form['code']);
      if (rejectCodes || user == null || form['client_secret'] != 'gh-secret') {
        return send(200, {'error': 'bad_verification_code'});
      }
      return send(200, {
        'access_token': 'gho_${user.id}',
        'token_type': 'bearer',
      });
    }

    final auth = request.headers.value('authorization') ?? '';
    final id = int.tryParse(auth.replaceFirst('Bearer gho_', ''));
    final user = _known.where((u) => u.id == id);
    if (user.isEmpty) return send(401, {'message': 'Bad credentials'});
    final u = user.last;
    if (request.uri.path == '/user') {
      return send(200, {
        'id': u.id,
        'login': u.login,
        'name': u.name,
        'avatar_url': 'https://avatars.example/${u.id}',
      });
    }
    if (request.uri.path == '/user/orgs') {
      if (orgsStatus != 200) return send(orgsStatus, {'message': 'nope'});
      return send(200, [
        for (final o in u.orgs) {'login': o},
      ]);
    }
    if (request.uri.path == '/user/emails') {
      return send(200, [
        for (final (address, verified) in u.emails)
          {'email': address, 'verified': verified, 'primary': false},
      ]);
    }
    send(404, {'message': 'Not Found'});
  }

  // Users stay known after their code is spent, like a live access token.
  final _known = <GhUser>[];
}
