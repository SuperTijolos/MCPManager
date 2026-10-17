import 'dart:async';

export 'oauth_popup_stub.dart'
    if (dart.library.js_interop) 'oauth_popup_web.dart';

/// A browser window used for the interactive part of the OAuth flow.
///
/// It must be opened synchronously inside a click handler (otherwise browsers
/// block it), so opening and navigating are separate steps: the window is
/// opened first, then pointed at the authorization URL once discovery is done.
abstract class OAuthPopup {
  void navigate(Uri url);

  /// The query parameters the callback page received (`code`, `state`, or
  /// `error`). Completes with an error if the user closes the window.
  Future<Map<String, String>> get result;

  void close();
}
