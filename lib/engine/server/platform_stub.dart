import 'dart:async';

import 'platform.dart';

/// Where the app is served from.
Uri currentAppUri() => Uri.base;

/// Leaves the app for [url] in the same window (used to sign in with GitHub).
void navigateTo(Uri url) {}

/// The session token the server handed back in the address (`#session=...`),
/// removed from the address bar once read. Null when there is none.
String? takeSessionFromUrl() => null;

AuthPopup openAuthPopup() =>
    throw PopupBlocked('Signing in to a server needs a browser.');

// Keeps the analyzer from flagging the unused import on non-web builds.
Future<void> never() => Completer<void>().future;
