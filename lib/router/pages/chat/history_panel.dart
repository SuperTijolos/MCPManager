import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/agent/chat_store.dart';
import '../../../ui/theme.dart';

/// The list of saved Operator conversations: search, switch, rename, delete.
class HistoryPanel extends ConsumerStatefulWidget {
  const HistoryPanel({super.key, this.onPicked});

  /// Called after a conversation was opened or a new one started (used to
  /// close the bottom sheet on narrow screens).
  final VoidCallback? onPicked;

  @override
  ConsumerState<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends ConsumerState<HistoryPanel> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final controller = ref.read(chatControllerProvider.notifier);
    final theme = Theme.of(context);
    final now = DateTime.now();

    final list = [
      for (final c in chat.conversations)
        if (_query.isEmpty || c.title.toLowerCase().contains(_query)) c,
    ];
    // Group under date headings, keeping the most-recent-first order.
    final rows = <Object>[];
    String? group;
    for (final c in list) {
      final g = historyGroup(c.updatedAt, now);
      if (g != group) {
        group = g;
        rows.add(g);
      }
      rows.add(c);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: FilledButton.tonalIcon(
            onPressed: () {
              controller.newConversation();
              widget.onPicked?.call();
            },
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text('New conversation'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search conversations',
            ),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: chat.conversations.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Your conversations will appear here.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : list.isEmpty
              ? const Center(child: Text('No matches'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    if (row is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                        child: Text(
                          row,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    final c = row as ConversationMeta;
                    final active = c.id == chat.activeId;
                    return ListTile(
                      dense: true,
                      selected: active,
                      selectedTileColor: theme.colorScheme.primary.withValues(
                        alpha: 0.14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      title: Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_time(c.updatedAt)} · ${c.messageCount} '
                        '${c.messageCount == 1 ? 'message' : 'messages'}',
                      ),
                      onTap: () {
                        controller.open(c.id);
                        widget.onPicked?.call();
                      },
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Conversation actions',
                        icon: const Icon(Icons.more_vert, size: 18),
                        onSelected: (v) {
                          if (v == 'rename') _rename(context, c);
                          if (v == 'delete') _delete(context, c);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (chat.conversations.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextButton.icon(
              onPressed: () => _deleteAll(context),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('Delete all'),
              style: TextButton.styleFrom(foregroundColor: StatusColors.bad),
            ),
          ),
      ],
    );
  }

  String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay
        ? '${two(t.hour)}:${two(t.minute)}'
        : '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  Future<void> _rename(BuildContext context, ConversationMeta c) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: c.title),
    );
    if (title != null) {
      ref.read(chatControllerProvider.notifier).rename(c.id, title);
    }
  }

  Future<void> _delete(BuildContext context, ConversationMeta c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${c.title}"?'),
        content: const Text('This conversation is removed from this browser.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(chatControllerProvider.notifier).delete(c.id);
  }

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all conversations?'),
        content: const Text(
          'Every saved conversation is removed from this browser. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(chatControllerProvider.notifier).deleteAll();
  }
}

/// Owns its text controller, so it is only disposed once the dialog has fully
/// left the screen (disposing right after `showDialog` returns would break the
/// closing animation).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename conversation'),
    content: TextField(
      controller: _field,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Title'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _field.text),
        child: const Text('Rename'),
      ),
    ],
  );
}
