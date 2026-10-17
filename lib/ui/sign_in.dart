import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/mcp/mcp_hub.dart';
import '../engine/mcp/oauth/oauth_models.dart';
import '../engine/mcp/oauth/oauth_popup.dart';
import '../engine/mcp/oauth/oauth_service.dart';
import 'widgets.dart';

/// Starts OAuth sign-in for [serverId]. The sign-in window is opened
/// synchronously from the click, before any `await`, or browsers block it.
Future<void> signInToServer(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) async {
  final OAuthPopup popup;
  try {
    popup = ref.read(oauthPopupOpenerProvider)();
  } on OAuthException catch (e) {
    showSnack(context, e.message);
    return;
  }
  final error = await ref
      .read(mcpHubProvider.notifier)
      .authorize(serverId, popup);
  if (error != null && context.mounted) showSnack(context, error);
}
