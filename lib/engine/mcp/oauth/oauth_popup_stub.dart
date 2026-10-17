import 'oauth_models.dart';
import 'oauth_popup.dart';

OAuthPopup openOAuthPopup() =>
    throw OAuthException('OAuth sign-in needs the web build of MCP Manager.');

/// Origin of the running app; there is no browser here.
Uri currentAppUri() => Uri.base;
