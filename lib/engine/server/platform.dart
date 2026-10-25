import 'dart:async';

export 'platform_stub.dart' if (dart.library.js_interop) 'platform_web.dart';

/// A browser window used for the interactive part of signing in to an
/// upstream MCP server. It must be opened synchronously inside a click
/// handler (or browsers block it), so opening and pointing it somewhere are
/// separate steps.
abstract class AuthPopup {
  /// Sends the window to [url].
  void navigate(Uri url);

  /// Completes when the person closes the window.
  Future<void> get closed;

  void close();
}

/// The popup could not be opened (pop-ups are blocked, or there is no browser).
class PopupBlocked implements Exception {
  PopupBlocked(this.message);
  final String message;

  @override
  String toString() => message;
}
