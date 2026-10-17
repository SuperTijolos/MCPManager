import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/core/json.dart';
import 'theme.dart';

class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.child,
    this.padded = true,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 16, kPagePadding, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.headlineSmall),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
        Expanded(
          child: padded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPagePadding,
                    8,
                    kPagePadding,
                    kPagePadding,
                  ),
                  child: child,
                )
              : child,
        ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                if (message != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 16), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, this.color, {super.key, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selectable, scrollable monospace block for JSON, logs and tool output.
class CodeBlock extends StatelessWidget {
  const CodeBlock(this.text, {super.key, this.maxHeight = 260});

  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant
              .withValues(alpha: 0.5),
        ),
      ),
      child: Stack(
        children: [
          Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                text.isEmpty ? '(empty)' : text,
                style: const TextStyle(
                  fontFamilyFallback: monoFonts,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: 'Copy',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class JsonBlock extends StatelessWidget {
  const JsonBlock(this.value, {super.key, this.maxHeight = 260});
  final Object? value;
  final double maxHeight;

  @override
  Widget build(BuildContext context) =>
      CodeBlock(prettyJson(value), maxHeight: maxHeight);
}

String formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String formatDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${formatTime(t)}';
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
