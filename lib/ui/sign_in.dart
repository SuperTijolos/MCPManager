import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/mcp/mcp_hub.dart';
import '../engine/server/platform.dart';
import 'widgets.dart';

/// Overridden in tests so no real window is needed.
final authPopupOpenerProvider = Provider<AuthPopup Function()>(
  (ref) => openAuthPopup,
);

/// Starts OAuth sign-in for [serverId]. The sign-in window is opened
/// synchronously from the click, before any `await`, or browsers block it.
Future<void> signInToServer(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) async {
  final AuthPopup popup;
  try {
    popup = ref.read(authPopupOpenerProvider)();
  } on PopupBlocked catch (e) {
    showSnack(context, e.message);
    return;
  }
  final error = await ref
      .read(mcpHubProvider.notifier)
      .authorize(serverId, popup);
  if (error != null && context.mounted) showSnack(context, error);
}
