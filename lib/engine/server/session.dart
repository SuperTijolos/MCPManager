import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../core/prefs.dart';
import 'platform.dart';
import 'server_client.dart';

const _storageKey = 'mcpm.session.v1';

/// Creates the HTTP client the app talks to the server with. Overridden in
/// tests to reach an in-process server.
final serverHttpClientProvider = Provider<http.Client Function()>(
  (ref) => http.Client.new,
);

/// Sends this window to another address (the server's GitHub sign-in).
/// Overridden in tests, where there is no browser to leave.
final sessionNavigatorProvider = Provider<void Function(Uri url)>(
  (ref) => navigateTo,
);

enum SessionStatus { signedOut, checking, signedIn }

/// Who the server says is signed in.
class SessionIdentity {
  const SessionIdentity({
    required this.kind,
    this.id,
    this.login,
    this.name,
    this.avatarUrl,
  });

  /// `member` (signed in with GitHub) or `admin` (the admin token).
  final String kind;
  final String? id;
  final String? login;
  final String? name;
  final String? avatarUrl;

  String get label => switch (kind) {
    'admin' => 'Admin token',
    _ => name ?? login ?? 'Member',
  };

  factory SessionIdentity.fromJson(Json json) {
    final member = (json['member'] as Map?)?.cast<String, dynamic>();
    return SessionIdentity(
      kind: json['kind'] as String? ?? 'member',
      id: member?['id'] as String?,
      login: member?['login'] as String?,
      name: member?['name'] as String?,
      avatarUrl: member?['avatarUrl'] as String?,
    );
  }
}

/// What a server offers for signing in.
class ServerSignIn {
  const ServerSignIn({required this.github, this.orgs = const []});
  final bool github;
  final List<String> orgs;
}

class SessionState {
  const SessionState({
    this.status = SessionStatus.signedOut,
    this.serverUrl,
    this.token,
    this.identity,
    this.error,
  });

  final SessionStatus status;
  final String? serverUrl;
  final String? token;
  final SessionIdentity? identity;

  /// Why the last sign-in or check failed, for the sign-in page.
  final String? error;

  bool get signedIn => status == SessionStatus.signedIn;
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);

/// The server's address and the token to talk to it with: the only things the
/// dashboard keeps about the server. Everything else lives on the server.
class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = readJson(prefs, _storageKey);
    var url = raw is Map ? raw['url'] as String? : null;
    var token = raw is Map ? raw['token'] as String? : null;

    // Coming back from the server's GitHub sign-in: the token is in the address.
    final handed = takeSessionFromUrl();
    if (handed != null && url != null && url.isNotEmpty) token = handed;

    if (url == null || url.isEmpty) {
      return SessionState(serverUrl: url);
    }
    if (token == null || token.isEmpty) {
      return SessionState(serverUrl: url);
    }
    _save(url, token);
    Future.microtask(_validate);
    return SessionState(
      status: SessionStatus.checking,
      serverUrl: url,
      token: token,
    );
  }

  /// Asks the server which sign-in methods it has (no credential needed).
  Future<ServerSignIn> inspect(String url) async {
    final client = ServerClient(
      baseUrl: url,
      token: '',
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final r = await client.getMap('/auth/config');
      return ServerSignIn(
        github: r['github'] == true,
        orgs: [for (final o in (r['orgs'] as List?) ?? const []) '$o'],
      );
    } finally {
      client.close();
    }
  }

  /// Signs in with the admin token. Returns an error message, or null.
  Future<String?> signInWithAdminToken(String url, String token) async {
    final address = normalizeServerUrl(url);
    final trimmed = token.trim();
    if (address.isEmpty) return 'Enter the server address.';
    if (trimmed.isEmpty) return 'Enter the admin token.';
    final client = ServerClient(
      baseUrl: address,
      token: trimmed,
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final me = await client.getMap('/api/me');
      _save(address, trimmed);
      state = SessionState(
        status: SessionStatus.signedIn,
        serverUrl: address,
        token: trimmed,
        identity: SessionIdentity.fromJson(me),
      );
      return null;
    } on ServerException catch (e) {
      return e.unauthorized ? 'That token is not accepted.' : e.message;
    } finally {
      client.close();
    }
  }

  /// Sends this window to the server's GitHub sign-in; it comes back here with
  /// a session. Returns an error message when that cannot start.
  Future<String?> beginGitHub(String url) async {
    final address = normalizeServerUrl(url);
    if (address.isEmpty) return 'Enter the server address.';
    try {
      final options = await inspect(address);
      if (!options.github) {
        return 'This server has no GitHub sign-in set up. Use the admin token.';
      }
    } on ServerException catch (e) {
      return e.message;
    }
    // Remember the address so the way back knows where the server is.
    _save(address, null);
    final here = currentAppUri().replace(fragment: '', query: '');
    final target = Uri.parse('$address/auth/github').replace(
      queryParameters: {'return_to': here.toString().replaceAll('#', '')},
    );
    ref.read(sessionNavigatorProvider)(target);
    return null;
  }

  Future<void> _validate() async {
    final url = state.serverUrl;
    final token = state.token;
    if (url == null || token == null) return;
    final client = ServerClient(
      baseUrl: url,
      token: token,
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final me = await client.getMap('/api/me');
      if (!ref.mounted) return;
      state = SessionState(
        status: SessionStatus.signedIn,
        serverUrl: url,
        token: token,
        identity: SessionIdentity.fromJson(me),
      );
    } on ServerException catch (e) {
      if (!ref.mounted) return;
      if (e.unauthorized) {
        _forget('Your session has ended. Sign in again.');
      } else {
        // The server may just be down: keep the token and say so.
        state = SessionState(serverUrl: url, token: token, error: e.message);
      }
    } finally {
      client.close();
    }
  }

  /// Tries again after the server could not be reached.
  Future<void> retry() async {
    if (state.token == null) return;
    state = SessionState(
      status: SessionStatus.checking,
      serverUrl: state.serverUrl,
      token: state.token,
    );
    await _validate();
  }

  /// The server refused our token.
  void expired() {
    if (state.status == SessionStatus.signedOut) return;
    _forget('Your session has ended. Sign in again.');
  }

  Future<void> signOut() async {
    final url = state.serverUrl;
    final token = state.token;
    if (url != null && token != null && state.identity?.kind == 'member') {
      final client = ServerClient(
        baseUrl: url,
        token: token,
        httpClient: ref.read(serverHttpClientProvider)(),
      );
      try {
        await client.send('POST', '/api/logout');
      } on ServerException {
        // Signing out locally is what matters.
      } finally {
        client.close();
      }
    }
    if (ref.mounted) _forget(null);
  }

  void _forget(String? message) {
    _save(state.serverUrl, null);
    state = SessionState(serverUrl: state.serverUrl, error: message);
  }

  void _save(String? url, String? token) {
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, {
      'url': ?url,
      'token': ?token,
    });
  }
}

/// Where an upstream MCP server sends the browser back after signing in: the
/// gateway's own callback, so the server needs no CORS and no app address.
final oauthRedirectUriProvider = Provider<Uri>((ref) {
  final url = ref.watch(sessionProvider).serverUrl ?? 'http://localhost:8787';
  return Uri.parse('$url/oauth/upstream/callback');
});

/// The client for the signed-in server, or null when nobody is signed in.
final serverClientProvider = Provider<ServerClient?>((ref) {
  final session = ref.watch(sessionProvider);
  final url = session.serverUrl;
  final token = session.token;
  if (!session.signedIn || url == null || token == null) return null;
  final client = ServerClient(
    baseUrl: url,
    token: token,
    httpClient: ref.read(serverHttpClientProvider)(),
    onUnauthorized: () => ref.read(sessionProvider.notifier).expired(),
  );
  ref.onDispose(client.close);
  return client;
});
