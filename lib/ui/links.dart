import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/app_info.dart';
import 'widgets.dart';

/// Opens [url] in a new tab; if the browser refuses, copies it instead so the
/// link is never lost.
Future<void> openLink(BuildContext context, WidgetRef ref, String url) async {
  final uri = Uri.parse(url);
  bool opened;
  try {
    opened = await ref.read(openUrlProvider)(uri);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      showSnack(context, 'Could not open the link; copied $url');
    }
  }
}
