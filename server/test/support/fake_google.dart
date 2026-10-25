import 'dart:convert';
import 'dart:io';

class GoogleUser {
  GoogleUser(this.sub, this.email, {this.verified = true, this.name});
  final String sub;
  final String email;
  final bool verified;
  final String? name;
}

/// Just enough of Google for the sign-in: the code exchange and the userinfo
/// endpoint.
class FakeGoogle {
  FakeGoogle._(this._server);

  final HttpServer _server;
  final _codes = <String, GoogleUser>{};
  final _known = <GoogleUser>[];
  var _next = 0;

  /// What the app sent, in order, as `METHOD path`.
  final requests = <String>[];
  final secretsSeen = <String>[];
  final redirectsSeen = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeGoogle> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final g = FakeGoogle._(server);
    server.listen(g._handle);
    return g;
  }

  String codeFor(GoogleUser user) {
    final code = 'gcode-${_next++}';
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

    if (request.uri.path == '/token') {
      final form = Uri.splitQueryString(body);
      secretsSeen.add(form['client_secret'] ?? '');
      redirectsSeen.add(form['redirect_uri'] ?? '');
      final user = _codes.remove(form['code']);
      if (user == null ||
          form['client_secret'] != 'g-secret' ||
          form['grant_type'] != 'authorization_code') {
        return send(400, {'error': 'invalid_grant'});
      }
      return send(200, {'access_token': 'ya29.${user.sub}'});
    }
    if (request.uri.path == '/userinfo') {
      final auth = request.headers.value('authorization') ?? '';
      final sub = auth.replaceFirst('Bearer ya29.', '');
      final user = _known.where((u) => u.sub == sub);
      if (user.isEmpty) return send(401, {'error': 'invalid_token'});
      final u = user.last;
      return send(200, {
        'sub': u.sub,
        'email': u.email,
        'email_verified': u.verified,
        'name': u.name,
        'picture': 'https://avatars.example/g/${u.sub}',
      });
    }
    send(404, {});
  }
}
