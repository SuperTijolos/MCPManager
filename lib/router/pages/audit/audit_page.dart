import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/audit/audit_log.dart';
import '../../../engine/audit/audit_models.dart';
import '../../../engine/core/json.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import '../overview/overview_page.dart' show statusColor, statusIcon;

class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  String _query = '';
  AuditStatus? _status;
  AuditSource? _source;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(auditLogProvider);
    final events = [
      for (final e in all)
        if ((_status == null || e.status == _status) &&
            (_source == null || e.source == _source) &&
            (_query.isEmpty || _matches(e, _query)))
          e,
    ];

    return PageScaffold(
      title: 'Audit log',
      subtitle:
          'Every tool call and connection, newest first · secrets redacted',
      actions: [
        IconButton(
          tooltip: 'Copy as JSON',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: events.isEmpty
              ? null
              : () {
                  Clipboard.setData(
                    ClipboardData(
                      text: prettyJson([for (final e in events) e.toJson()]),
                    ),
                  );
                  showSnack(context, 'Copied ${events.length} events');
                },
        ),
        IconButton(
          tooltip: 'Clear log',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: all.isEmpty ? null : () => _confirmClear(context),
        ),
      ],
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search',
                  ),
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                ),
              ),
              for (final s in AuditStatus.values)
                FilterChip(
                  label: Text(s.name),
                  selected: _status == s,
                  onSelected: (on) => setState(() => _status = on ? s : null),
                ),
              DropdownButton<AuditSource?>(
                value: _source,
                hint: const Text('Source'),
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All sources'),
                  ),
                  for (final s in AuditSource.values)
                    DropdownMenuItem(value: s, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _source = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: events.isEmpty
                ? EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: all.isEmpty
                        ? 'No events yet'
                        : 'No events match the filters',
                    message: all.isEmpty
                        ? 'Tool calls and server connections will be recorded here.'
                        : null,
                  )
                : ListView.separated(
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _EventTile(events[i]),
                  ),
          ),
        ],
      ),
    );
  }

  bool _matches(AuditEvent e, String q) =>
      e.title.toLowerCase().contains(q) ||
      e.actor.toLowerCase().contains(q) ||
      (e.args ?? '').toLowerCase().contains(q) ||
      (e.result ?? '').toLowerCase().contains(q) ||
      (e.error ?? '').toLowerCase().contains(q);

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the audit log?'),
        content: const Text(
          'All recorded events will be deleted from this browser. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(auditLogProvider.notifier).clear();
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile(this.event);
  final AuditEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(
            statusIcon(event.status),
            color: statusColor(event.status),
          ),
          title: Text(event.title, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${formatDateTime(event.timestamp)} · ${event.actor}'
            '${event.durationMs == null ? '' : ' · ${event.durationMs} ms'}',
          ),
          trailing: StatusChip(event.status.name, statusColor(event.status)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                StatusChip(event.source.name, StatusColors.muted),
                if (event.approval != null)
                  StatusChip('approval: ${event.approval}', StatusColors.info),
              ],
            ),
            if (event.args != null) ...[
              const SizedBox(height: 10),
              const Text('Arguments'),
              const SizedBox(height: 4),
              CodeBlock(event.args!, maxHeight: 160),
            ],
            if (event.result != null) ...[
              const SizedBox(height: 10),
              const Text('Result'),
              const SizedBox(height: 4),
              CodeBlock(event.result!, maxHeight: 220),
            ],
            if (event.error != null) ...[
              const SizedBox(height: 10),
              const Text('Error'),
              const SizedBox(height: 4),
              CodeBlock(event.error!, maxHeight: 160),
            ],
            const SizedBox(height: 8),
            SelectableText(
              event.id,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
