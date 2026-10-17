import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'oauth_models.dart';
import 'oauth_popup.dart';

const _messageType = 'mcpm-oauth';
const _channelName = 'mcpm-oauth';

OAuthPopup openOAuthPopup() => _WebOAuthPopup.open();

Uri currentAppUri() => Uri.parse(web.window.location.href);

class _WebOAuthPopup implements OAuthPopup {
  _WebOAuthPopup._(this._window) {
    _messageListener = _onMessage.toJS;
    web.window.addEventListener('message', _messageListener);
    // Fallback for providers whose Cross-Origin-Opener-Policy severs
    // `window.opener`: the callback page also broadcasts on a channel.
    _channel = web.BroadcastChannel(_channelName)..onmessage = _onMessage.toJS;
    _closedPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_window.closed) {
        _fail('The sign-in window was closed before finishing.');
      }
    });
  }

  factory _WebOAuthPopup.open() {
    final window = web.window.open(
      '',
      'mcpm_oauth',
      'popup,width=520,height=720',
    );
    if (window == null) {
      throw OAuthException(
        'The browser blocked the sign-in window. Allow pop-ups for this site and try again.',
      );
    }
    return _WebOAuthPopup._(window);
  }

  final web.Window _window;
  final _completer = Completer<Map<String, String>>();
  late final JSFunction _messageListener;
  late final web.BroadcastChannel _channel;
  late final Timer _closedPoll;

  @override
  Future<Map<String, String>> get result => _completer.future;

  @override
  void navigate(Uri url) => _window.location.href = url.toString();

  void _onMessage(web.MessageEvent event) {
    final data = event.data.dartify();
    if (data is! Map || data['type'] != _messageType) return;
    // postMessage carries an origin; BroadcastChannel is same-origin by design.
    if (event.origin.isNotEmpty && event.origin != web.window.location.origin) {
      return;
    }
    final params = data['params'];
    if (params is! Map || _completer.isCompleted) return;
    _completer.complete({
      for (final e in params.entries) '${e.key}': '${e.value}',
    });
  }

  void _fail(String message) {
    if (!_completer.isCompleted) {
      _completer.completeError(OAuthException(message));
    }
  }

  @override
  void close() {
    _closedPoll.cancel();
    web.window.removeEventListener('message', _messageListener);
    _channel.close();
    if (!_window.closed) _window.close();
  }
}
