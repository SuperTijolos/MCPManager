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

/// The audit log is shown as two views: calls to MCP tools, and what the app
/// itself did (connections, sign-ins and management actions).
enum _View {
  tools,
  activity;

  Set<AuditKind> get kinds => switch (this) {
    _View.tools => const {AuditKind.toolCall},
    _View.activity => const {
      AuditKind.serverConnect,
      AuditKind.authorize,
      AuditKind.manage,
    },
  };
}

class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  final _scroll = ScrollController();
  _View _view = _View.tools;
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

  void _switchView(_View view) => _filter(() {
    _view = view;
    _kind = null;
  });

  void _goTo(int page) {
    setState(() => _page = page);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(auditLogProvider);
    final inView = [
      for (final e in all)
        if (_view.kinds.contains(e.kind)) e,
    ];
    final toolCount = all
        .where((e) => _View.tools.kinds.contains(e.kind))
        .length;
    final activityCount = all.length - toolCount;

    final events = [
      for (final e in inView)
        if ((_kind == null || e.kind == _kind) &&
            (_status == null || e.status == _status) &&
            (_source == null || e.source == _source) &&
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
          ? '${events.length} of ${inView.length} events match · newest first'
          : '${inView.length} events · newest first · secrets redacted',
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<_View>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _View.tools,
                icon: const Icon(Icons.build_outlined),
                label: Text('MCP tools ($toolCount)'),
              ),
              ButtonSegment(
                value: _View.activity,
                icon: const Icon(Icons.dashboard_outlined),
                label: Text('Dashboard ($activityCount)'),
              ),
            ],
            selected: {_view},
            onSelectionChanged: (s) => _switchView(s.first),
          ),
          const SizedBox(height: 12),
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
              if (_view == _View.activity)
                DropdownButton<AuditKind?>(
                  value: _kind,
                  hint: const Text('Type'),
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All activity'),
                    ),
                    for (final k in _View.activity.kinds)
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
                    title: inView.isEmpty
                        ? (_view == _View.tools
                              ? 'No tool calls yet'
                              : 'No dashboard activity yet')
                        : 'No events match the filters',
                    message: inView.isEmpty
                        ? (_view == _View.tools
                              ? 'Calls to MCP tools, from the Tools page or the Operator, appear here.'
                              : 'Connections, sign-ins and changes made from the app appear here.')
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

/// The summary row. Tapping it opens the full event in a dialog.
class _EventTile extends StatelessWidget {
  const _EventTile(this.event);
  final AuditEvent event;

  /// The audit-only values the model supplied, as `reason: …` text, so the
  /// "why" is visible without opening the event.
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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final contextLine = _contextLine;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showAuditDetail(context, event),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(statusIcon(event.status), color: statusColor(event.status)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      '${formatDateTime(event.timestamp)} · ${event.actor}'
                      '${event.durationMs == null ? '' : ' · ${event.durationMs} ms'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
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
              ),
              const SizedBox(width: 8),
              StatusChip(event.status.name, statusColor(event.status)),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showAuditDetail(BuildContext context, AuditEvent event) =>
    showDialog<void>(
      context: context,
      builder: (_) => _AuditDetailDialog(event),
    );

/// Everything recorded for one event: who, when, what was sent, what the
/// server received, and what came back.
class _AuditDetailDialog extends StatelessWidget {
  const _AuditDetailDialog(this.event);
  final AuditEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    statusIcon(event.status),
                    color: statusColor(event.status),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      event.title,
                      style: theme.textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy as JSON',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: prettyJson(event.toJson())),
                      );
                      showSnack(context, 'Copied this event');
                    },
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(
                '${formatDateTime(event.timestamp)} · ${event.actor}'
                '${event.durationMs == null ? '' : ' · ${event.durationMs} ms'}',
                style: muted,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  StatusChip(event.status.name, statusColor(event.status)),
                  StatusChip(event.source.name, StatusColors.muted),
                  if (event.approval != null)
                    StatusChip(
                      'approval: ${event.approval}',
                      StatusColors.info,
                    ),
                  if (event.forwarded != null)
                    const StatusChip(
                      'reshaped by rules',
                      StatusColors.warn,
                      icon: Icons.tune,
                    ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (event.args != null)
                        _section(
                          event.forwarded != null
                              ? 'Arguments from the model'
                              : 'Arguments',
                          event.args!,
                          200,
                        ),
                      if (event.forwarded != null)
                        _section(
                          'Forwarded to the server',
                          event.forwarded!,
                          200,
                        ),
                      if (event.context != null)
                        _section(
                          'Audit-only context (not sent to the server)',
                          event.context!,
                          140,
                        ),
                      if (event.result != null)
                        _section('Result', event.result!, 260),
                      if (event.error != null)
                        _section('Error', event.error!, 180),
                    ],
                  ),
                ),
              ),
              const Divider(),
              SelectableText('Event ${event.id}', style: muted),
            ],
          ),
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
