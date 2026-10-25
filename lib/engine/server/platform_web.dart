import 'dart:async';

import 'package:web/web.dart' as web;

import 'platform.dart';

Uri currentAppUri() => Uri.parse(web.window.location.href);

void navigateTo(Uri url) => web.window.location.assign(url.toString());

String? takeSessionFromUrl() {
  final fragment = web.window.location.hash;
  if (fragment.length < 2) return null;
  final params = Uri.splitQueryString(fragment.substring(1));
  final token = params['session'];
  if (token == null || token.isEmpty) return null;
  // Do not leave the token in the address bar or the history.
  final clean = Uri.parse(web.window.location.href).removeFragment();
  web.window.history.replaceState(null, '', clean.toString());
  return token;
}

AuthPopup openAuthPopup() {
  final window = web.window.open(
    '',
    'mcpm_signin',
    'popup,width=520,height=720',
  );
  if (window == null) {
    throw PopupBlocked(
      'The browser blocked the sign-in window. Allow pop-ups for this site and try again.',
    );
  }
  return _WebPopup(window);
}

class _WebPopup implements AuthPopup {
  _WebPopup(this._window) {
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_window.closed && !_closed.isCompleted) {
        _poll.cancel();
        _closed.complete();
      }
    });
  }

  final web.Window _window;
  final _closed = Completer<void>();
  late final Timer _poll;

  @override
  Future<void> get closed => _closed.future;

  @override
  void navigate(Uri url) => _window.location.href = url.toString();

  @override
  void close() {
    _poll.cancel();
    if (!_closed.isCompleted) _closed.complete();
    if (!_window.closed) _window.close();
  }
}
