import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/audit/audit_log.dart';
import '../../../engine/audit/audit_models.dart';
import '../../../engine/core/json.dart';
import '../../../ui/pagination.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import '../overview/overview_page.dart' show statusColor, statusIcon;

class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  final _scroll = ScrollController();
  String _query = '';
  AuditStatus? _status;
  AuditSource? _source;
  AuditKind? _kind;
  int _page = 0;
  int _pageSize = 25;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _filtered =>
      _query.isNotEmpty || _status != null || _source != null || _kind != null;

  /// Any filter change goes back to the first page.
  void _filter(VoidCallback change) => setState(() {
    change();
    _page = 0;
  });

  void _goTo(int page) {
    setState(() => _page = page);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(auditLogProvider);
    final events = [
      for (final e in all)
        if ((_status == null || e.status == _status) &&
            (_source == null || e.source == _source) &&
            (_kind == null || e.kind == _kind) &&
            (_query.isEmpty || _matches(e, _query)))
          e,
    ];
    final range = PageRange(
      total: events.length,
      page: _page,
      pageSize: _pageSize,
    );

    return PageScaffold(
      title: 'Audit log',
      subtitle: _filtered
          ? '${events.length} of ${all.length} events match · newest first'
          : '${all.length} events · newest first · secrets redacted',
      actions: [
        IconButton(
          tooltip: 'Copy ${_filtered ? 'filtered ' : ''}events as JSON',
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
                      _filter(() => _query = v.trim().toLowerCase()),
                ),
              ),
              for (final s in AuditStatus.values)
                FilterChip(
                  label: Text(s.name),
                  selected: _status == s,
                  onSelected: (on) => _filter(() => _status = on ? s : null),
                ),
              DropdownButton<AuditKind?>(
                value: _kind,
                hint: const Text('Type'),
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All types')),
                  for (final k in AuditKind.values)
                    DropdownMenuItem(value: k, child: Text(_kindLabel(k))),
                ],
                onChanged: (v) => _filter(() => _kind = v),
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
                onChanged: (v) => _filter(() => _source = v),
              ),
              if (_filtered)
                TextButton.icon(
                  onPressed: () => _filter(() {
                    _query = '';
                    _status = null;
                    _source = null;
                    _kind = null;
                  }),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Reset filters'),
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
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.separated(
                      controller: _scroll,
                      itemCount: range.end - range.start,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _EventTile(events[range.start + i]),
                    ),
                  ),
          ),
          if (events.isNotEmpty)
            PaginationBar(
              range: range,
              onPage: _goTo,
              onPageSize: (n) => setState(() {
                _pageSize = n;
                _page = 0;
              }),
            ),
        ],
      ),
    );
  }

  String _kindLabel(AuditKind k) => switch (k) {
    AuditKind.toolCall => 'Tool calls',
    AuditKind.serverConnect => 'Connections',
    AuditKind.authorize => 'Sign-ins',
    AuditKind.manage => 'Management',
  };

  bool _matches(AuditEvent e, String q) =>
      e.title.toLowerCase().contains(q) ||
      e.actor.toLowerCase().contains(q) ||
      (e.args ?? '').toLowerCase().contains(q) ||
      (e.forwarded ?? '').toLowerCase().contains(q) ||
      (e.context ?? '').toLowerCase().contains(q) ||
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
    if (ok == true) {
      ref.read(auditLogProvider.notifier).clear();
      setState(() => _page = 0);
    }
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile(this.event);
  final AuditEvent event;

  /// The audit-only values the model supplied, as `reason: …` text for the
  /// collapsed row, so the "why" is visible without opening the event.
  String? get _contextLine {
    final raw = event.context;
    if (raw == null) return null;
    final decoded = tryDecodeObject(raw);
    if (decoded == null || decoded.isEmpty) return null;
    return decoded.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contextLine = _contextLine;
    return Card(
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(
            statusIcon(event.status),
            color: statusColor(event.status),
          ),
          title: Text(event.title, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${formatDateTime(event.timestamp)} · ${event.actor}'
                '${event.durationMs == null ? '' : ' · ${event.durationMs} ms'}',
              ),
              if (contextLine != null)
                Text(
                  contextLine,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
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
                if (event.forwarded != null)
                  const StatusChip(
                    'reshaped by rules',
                    StatusColors.warn,
                    icon: Icons.tune,
                  ),
              ],
            ),
            if (event.args != null)
              _section(
                event.forwarded != null
                    ? 'Arguments from the model'
                    : 'Arguments',
                event.args!,
                160,
              ),
            if (event.forwarded != null)
              _section('Forwarded to the server', event.forwarded!, 160),
            if (event.context != null)
              _section(
                'Audit-only context (not sent to the server)',
                event.context!,
                120,
              ),
            if (event.result != null) _section('Result', event.result!, 220),
            if (event.error != null) _section('Error', event.error!, 160),
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

  Widget _section(String label, String text, double maxHeight) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 4),
        CodeBlock(_pretty(text), maxHeight: maxHeight),
      ],
    ),
  );

  /// Stored previews are compact JSON; show objects indented.
  String _pretty(String text) {
    final t = text.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      } catch (_) {}
    }
    return text;
  }
}
