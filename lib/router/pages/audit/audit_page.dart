import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/audit/audit_export.dart';
import '../../../engine/audit/audit_log.dart';
import '../../../engine/audit/audit_text.dart';
import '../../../engine/audit/audit_models.dart';
import '../../../engine/core/json.dart';
import '../../../engine/core/redact.dart' show previewWasShortened, redacted;
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules.dart' show toolKey;
import '../../../ui/download.dart';
import '../../../ui/pagination.dart';
import '../../../ui/preview_section.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import '../overview/overview_page.dart' show statusColor, statusIcon;
import '../tools/tool_focus.dart';

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

enum _Range {
  any('Any time', null),
  hour('Last hour', Duration(hours: 1)),
  day('Last 24 hours', Duration(hours: 24)),
  week('Last 7 days', Duration(days: 7));

  const _Range(this.label, this.span);
  final String label;
  final Duration? span;
}

/// What identifies a server in an event even after it was removed.
String? _serverKey(AuditEvent e) => e.serverId ?? e.serverName;

String _day(DateTime t, DateTime now) {
  DateTime d(DateTime x) => DateTime(x.year, x.month, x.day);
  final days = d(now).difference(d(t)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return formatDateTime(t).substring(0, 10);
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _events(int n) => '$n event${n == 1 ? '' : 's'}';

/// Who did it, in words: "You", "Chat · model-name", "System".
String actorLabel(String actor) {
  if (actor == 'user') return 'You';
  if (actor == 'system') return 'System';
  if (actor.startsWith('operator:')) {
    final model = actor.substring('operator:'.length);
    // "nvidia/model:free" → "model:free": the provider prefix only adds length.
    final short = model.contains('/')
        ? model.substring(model.lastIndexOf('/') + 1)
        : model;
    return short.isEmpty ? 'Chat' : 'Chat · $short';
  }
  return actor;
}

String? _approvalLabel(String? approval) => switch (approval) {
  'auto' => 'read-only, ran automatically',
  'user' => 'approved by you',
  'session' => 'always allowed',
  'automatic' => 'automatic mode',
  'denied' => 'denied by you',
  _ => null,
};

/// One line of what came back: the error, else the result. JSON is described
/// by its keys, with long text shown as its size.
({String text, bool isError})? _outcomeLine(AuditEvent e) {
  final raw = e.error ?? e.result;
  if (raw == null || raw.trim().isEmpty) return null;
  return (text: summarizeResult(raw), isError: e.error != null);
}

/// Who or what started an event, in words.
String sourceLabel(AuditSource s) => switch (s) {
  AuditSource.workbench => 'Tools page',
  AuditSource.operator => 'Chat',
  AuditSource.system => 'System',
};

/// A run of identical successful events, such as the same server connecting
/// again on every page load. Shown as one row.
class _Row {
  _Row(AuditEvent first) : events = [first];
  final List<AuditEvent> events;

  bool get isGroup => events.length > 1;

  bool accepts(AuditEvent e) {
    final head = events.first;
    return head.status == AuditStatus.success &&
        e.status == AuditStatus.success &&
        head.kind == e.kind &&
        head.serverId != null &&
        head.serverId == e.serverId &&
        head.title == e.title;
  }
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
  _Range _range = _Range.any;
  String? _server;
  String? _tool;
  int _page = 0;
  int _pageSize = 25;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _filtered =>
      _query.isNotEmpty ||
      _status != null ||
      _source != null ||
      _kind != null ||
      _range != _Range.any ||
      _server != null ||
      _tool != null;

  /// Any filter change goes back to the first page.
  void _filter(VoidCallback change) => setState(() {
    change();
    _page = 0;
  });

  void _switchView(_View view) => _filter(() {
    _view = view;
    _kind = null;
    _server = null;
    _tool = null;
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

    final now = DateTime.now();
    final since = _range.span == null ? null : now.subtract(_range.span!);
    final events = [
      for (final e in inView)
        if ((_kind == null || e.kind == _kind) &&
            (_status == null || e.status == _status) &&
            (_source == null || e.source == _source) &&
            (since == null || e.timestamp.isAfter(since)) &&
            (_server == null || _serverKey(e) == _server) &&
            (_tool == null || e.toolName == _tool) &&
            (_query.isEmpty || _matches(e, _query)))
          e,
    ];
    // Choices for the server and tool filters come from what is in this view.
    final servers = <String, String>{
      for (final e in inView)
        if (_serverKey(e) != null)
          _serverKey(e)!: e.serverName ?? _serverKey(e)!,
    };
    final tools = <String>{
      for (final e in inView)
        if (e.toolName != null &&
            e.kind == AuditKind.toolCall &&
            (_server == null || _serverKey(e) == _server))
          e.toolName!,
    }.toList()..sort();
    // Only the activity view folds repeats; tool calls are always one each.
    final rows = <_Row>[];
    for (final e in events) {
      if (_view == _View.activity && rows.isNotEmpty && rows.last.accepts(e)) {
        rows.last.events.add(e);
      } else {
        rows.add(_Row(e));
      }
    }
    final range = PageRange(
      total: rows.length,
      page: _page,
      pageSize: _pageSize,
    );

    // The page's rows, with a heading wherever the day changes.
    final entries = <Object>[];
    DateTime? lastDay;
    for (final row in rows.sublist(range.start, range.end)) {
      final at = row.events.first.timestamp;
      if (lastDay == null || !_sameDay(lastDay, at)) {
        entries.add(_day(at, now));
        lastDay = at;
      }
      entries.add(row);
    }

    return PageScaffold(
      title: 'Audit log',
      subtitle: _filtered
          ? '${events.length} of ${_events(inView.length)} match · newest first'
          : '${_events(inView.length)} · newest first · secrets redacted',
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
          key: const ValueKey('audit-export'),
          tooltip: 'Export ${_filtered ? 'filtered ' : ''}events as a file',
          icon: const Icon(Icons.download_outlined),
          onPressed: events.isEmpty
              ? null
              : () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      _ExportDialog(events: events, filtered: _filtered),
                ),
        ),
        IconButton(
          key: const ValueKey('audit-clear'),
          tooltip: 'Clear events…',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: all.isEmpty ? null : () => _clear(context, all),
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
                label: Text('Activity ($activityCount)'),
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
              DropdownButton<_Range>(
                key: const ValueKey('audit-range'),
                value: _range,
                underline: const SizedBox.shrink(),
                items: [
                  for (final r in _Range.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: (v) => _filter(() => _range = v ?? _Range.any),
              ),
              if (servers.length > 1 || _server != null)
                DropdownButton<String?>(
                  key: const ValueKey('audit-server'),
                  value: servers.containsKey(_server) ? _server : null,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All servers'),
                    ),
                    for (final e in servers.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => _filter(() {
                    _server = v;
                    _tool = null;
                  }),
                ),
              if (_view == _View.tools && (tools.length > 1 || _tool != null))
                DropdownButton<String?>(
                  key: const ValueKey('audit-tool'),
                  value: tools.contains(_tool) ? _tool : null,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All tools'),
                    ),
                    for (final t in tools)
                      DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) => _filter(() => _tool = v),
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
                    DropdownMenuItem(value: s, child: Text(sourceLabel(s))),
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
                    _range = _Range.any;
                    _server = null;
                    _tool = null;
                  }),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Reset filters'),
                ),
            ],
          ),
          if (all.length >= auditCapacity)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: StatusColors.warn,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'The log keeps the latest $auditCapacity events. Older '
                      'ones are dropped as new ones arrive, so export what you '
                      'need to keep.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: events.isEmpty
                ? EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: inView.isEmpty
                        ? (_view == _View.tools
                              ? 'No tool calls yet'
                              : 'No activity yet')
                        : 'No events match the filters',
                    message: inView.isEmpty
                        ? (_view == _View.tools
                              ? 'Calls to MCP tools, from the Tools page or the Operator, appear here.'
                              : 'Connections, sign-ins and changes made from the app appear here.')
                        : null,
                  )
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        if (entry is String) {
                          return Padding(
                            padding: EdgeInsets.only(
                              top: i == 0 ? 0 : 12,
                              bottom: 6,
                            ),
                            child: Text(
                              entry,
                              key: ValueKey('audit-day-$entry'),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          );
                        }
                        final row = entry as _Row;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: row.isGroup
                              ? _GroupTile(row.events)
                              : _EventTile(row.events.single),
                        );
                      },
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

  Future<void> _clear(BuildContext context, List<AuditEvent> all) async {
    final scope = await showDialog<_ClearScope>(
      context: context,
      builder: (_) => _ClearDialog(all),
    );
    if (scope == null || !mounted) return;
    final log = ref.read(auditLogProvider.notifier);
    final removed = scope == _ClearScope.everything
        ? ref.read(auditLogProvider).length
        : log.removeWhere((e) => scope.matches(e, DateTime.now()));
    if (scope == _ClearScope.everything) log.clear();
    setState(() => _page = 0);
    if (context.mounted) showSnack(context, 'Cleared ${_events(removed)}');
  }
}

/// What "Clear events" removes.
enum _ClearScope {
  everything('Everything', 'The whole log.'),
  tools('Tool calls only', 'Keeps connections, sign-ins and management.'),
  activity('Activity only', 'Connections, sign-ins and management actions.'),
  older7('Older than 7 days', 'Keeps the last week.'),
  older30('Older than 30 days', 'Keeps the last month.');

  const _ClearScope(this.label, this.detail);
  final String label;
  final String detail;

  bool matches(AuditEvent e, DateTime now) => switch (this) {
    everything => true,
    tools => e.kind == AuditKind.toolCall,
    activity => e.kind != AuditKind.toolCall,
    older7 => e.timestamp.isBefore(now.subtract(const Duration(days: 7))),
    older30 => e.timestamp.isBefore(now.subtract(const Duration(days: 30))),
  };
}

class _ClearDialog extends StatefulWidget {
  const _ClearDialog(this.events);
  final List<AuditEvent> events;

  @override
  State<_ClearDialog> createState() => _ClearDialogState();
}

class _ClearDialogState extends State<_ClearDialog> {
  _ClearScope _scope = _ClearScope.older7;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    int count(_ClearScope s) =>
        widget.events.where((e) => s.matches(e, now)).length;
    final n = count(_scope);
    return AlertDialog(
      title: const Text('Clear events'),
      content: SizedBox(
        width: 420,
        child: RadioGroup<_ClearScope>(
          groupValue: _scope,
          onChanged: (v) => setState(() => _scope = v ?? _scope),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in _ClearScope.values)
                RadioListTile<_ClearScope>(
                  key: ValueKey('clear-${s.name}'),
                  value: s,
                  dense: true,
                  title: Text('${s.label} (${count(s)})'),
                  subtitle: Text(s.detail),
                ),
              const SizedBox(height: 8),
              const Text(
                'Cleared events are deleted from this browser and cannot be '
                'recovered. Export first if you may need them.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('clear-confirm'),
          onPressed: n == 0 ? null : () => Navigator.pop(context, _scope),
          child: Text('Clear ${_events(n)}'),
        ),
      ],
    );
  }
}

enum _ExportFormat { json, csv }

/// Saves the events as a file, or copies them.
class _ExportDialog extends ConsumerStatefulWidget {
  const _ExportDialog({required this.events, required this.filtered});
  final List<AuditEvent> events;
  final bool filtered;

  @override
  ConsumerState<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<_ExportDialog> {
  _ExportFormat _format = _ExportFormat.json;

  String get _content => _format == _ExportFormat.json
      ? prettyJson([for (final e in widget.events) e.toJson()])
      : auditToCsv(widget.events);

  String get _filename {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'mcp-manager-audit-$stamp.${_format.name}';
  }

  void _download() {
    final saved = ref.read(fileDownloadProvider)(
      _filename,
      _content,
      mime: _format == _ExportFormat.json ? 'application/json' : 'text/csv',
    );
    if (!saved) {
      Clipboard.setData(ClipboardData(text: _content));
    }
    Navigator.pop(context);
    showSnack(
      context,
      saved
          ? 'Saved ${_events(widget.events.length)} as $_filename'
          : 'Downloads are not available here; copied '
                '${_events(widget.events.length)} instead',
    );
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _content));
    Navigator.pop(context);
    showSnack(context, 'Copied ${_events(widget.events.length)}');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export events'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_events(widget.events.length)}'
              '${widget.filtered ? ' (the ones matching your filters)' : ''}. '
              'Secrets were already masked when each event was recorded.',
            ),
            const SizedBox(height: 14),
            SegmentedButton<_ExportFormat>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _ExportFormat.json,
                  label: Text('JSON'),
                  icon: Icon(Icons.data_object, size: 18),
                ),
                ButtonSegment(
                  value: _ExportFormat.csv,
                  label: Text('CSV'),
                  icon: Icon(Icons.table_chart_outlined, size: 18),
                ),
              ],
              selected: {_format},
              onSelectionChanged: (s) => setState(() => _format = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _format == _ExportFormat.json
                  ? 'Complete records, for other tools or a backup.'
                  : 'One row per event, for a spreadsheet.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('export-copy'),
          onPressed: _copy,
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Copy'),
        ),
        FilledButton.icon(
          key: const ValueKey('export-download'),
          onPressed: _download,
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('Download'),
        ),
      ],
    );
  }
}

/// "2026-10-18 11:59:05 · Chat · model · 76 ms · approved by you".
String _metaLine(
  AuditEvent event, {
  bool withApproval = true,
  bool timeOnly = false,
}) => [
  timeOnly ? formatTime(event.timestamp) : formatDateTime(event.timestamp),
  actorLabel(event.actor),
  if (event.durationMs != null) '${event.durationMs} ms',
  ?(withApproval ? _approvalLabel(event.approval) : null),
].join(' · ');

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
                      _metaLine(event, timeOnly: true),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                    if (_outcomeLine(event) case final outcome?)
                      Text(
                        outcome.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted?.copyWith(
                          color: outcome.isError ? StatusColors.bad : null,
                        ),
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

/// Several identical successful events folded into one row; expand it to see
/// each time it happened.
class _GroupTile extends StatelessWidget {
  const _GroupTile(this.events);

  /// Newest first.
  final List<AuditEvent> events;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final newest = events.first;
    final oldest = events.last;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey('audit-group-${newest.id}'),
          tilePadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
          leading: Icon(
            statusIcon(newest.status),
            color: statusColor(newest.status),
          ),
          title: Text(
            '${newest.title}  ×${events.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          subtitle: Text(
            _sameDay(newest.timestamp, oldest.timestamp)
                ? '${formatTime(newest.timestamp)} back to '
                      '${formatTime(oldest.timestamp)} · ${actorLabel(newest.actor)}'
                : '${formatDateTime(newest.timestamp)} back to '
                      '${formatDateTime(oldest.timestamp)} · ${actorLabel(newest.actor)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: StatusChip(newest.status.name, statusColor(newest.status)),
          children: [
            for (final e in events)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.fromLTRB(60, 0, 12, 0),
                title: Text(
                  [
                    formatTime(e.timestamp),
                    if (e.durationMs != null) '${e.durationMs} ms',
                    if (e.result != null) e.result!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => showAuditDetail(context, e),
              ),
          ],
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
class _AuditDetailDialog extends ConsumerWidget {
  const _AuditDetailDialog(this.event);
  final AuditEvent event;

  /// The arguments as recorded, when they can safely start a new test: they
  /// parse, were not shortened, and hold no masked secret that would be sent
  /// as the text "[redacted]".
  Json? get _reusableArgs {
    final raw = event.args;
    if (raw == null) return const {};
    if (previewWasShortened(raw) || raw.contains(redacted)) return null;
    return tryDecodeObject(raw);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hub = ref.watch(mcpHubProvider);
    final chat = ref.watch(chatControllerProvider);
    final toolStillThere =
        event.kind == AuditKind.toolCall &&
        event.serverId != null &&
        event.toolName != null &&
        (hub
                .byId(event.serverId!)
                ?.tools
                .any((t) => t.name == event.toolName) ??
            false);
    final chatStillThere =
        event.conversationId != null &&
        chat.conversations.any((c) => c.id == event.conversationId);
    final args = _reusableArgs;

    void go(void Function(GoRouter router) navigate) {
      final router = GoRouter.of(context);
      Navigator.pop(context);
      navigate(router);
    }

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
              Text(_metaLine(event, withApproval: false), style: muted),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  StatusChip(event.status.name, statusColor(event.status)),
                  StatusChip(sourceLabel(event.source), StatusColors.muted),
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
                        PreviewSection(
                          event.forwarded != null
                              ? 'Arguments from the model'
                              : 'Arguments',
                          event.args!,
                          200,
                        ),
                      if (event.forwarded != null)
                        PreviewSection(
                          'Forwarded to the server',
                          event.forwarded!,
                          200,
                        ),
                      if (event.context != null)
                        PreviewSection(
                          'Audit-only context (not sent to the server)',
                          event.context!,
                          140,
                        ),
                      if (event.result != null)
                        PreviewSection('Result', event.result!, 260),
                      if (event.error != null)
                        PreviewSection('Error', event.error!, 180),
                    ],
                  ),
                ),
              ),
              if (toolStillThere || chatStillThere)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (toolStillThere)
                        TextButton.icon(
                          key: const ValueKey('audit-open-tool'),
                          onPressed: () => go(
                            (r) => r.go(
                              '/mcp-tools',
                              extra: ToolFocus(
                                toolKey(event.serverId!, event.toolName!),
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.build_outlined, size: 18),
                          label: const Text('Open tool'),
                        ),
                      if (toolStillThere && args != null)
                        TextButton.icon(
                          key: const ValueKey('audit-test-again'),
                          onPressed: () => go(
                            (r) => r.go(
                              '/mcp-tools',
                              extra: ToolFocus(
                                toolKey(event.serverId!, event.toolName!),
                                args: args,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.replay, size: 18),
                          label: const Text('Test again'),
                        ),
                      if (chatStillThere)
                        TextButton.icon(
                          key: const ValueKey('audit-open-chat'),
                          onPressed: () {
                            ref
                                .read(chatControllerProvider.notifier)
                                .open(event.conversationId!);
                            go((r) => r.go('/chat'));
                          },
                          icon: const Icon(Icons.chat_bubble_outline, size: 18),
                          label: const Text('Open chat'),
                        ),
                    ],
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
}
