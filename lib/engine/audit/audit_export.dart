import 'audit_models.dart';

const _csvColumns = [
  'time',
  'kind',
  'status',
  'source',
  'actor',
  'server',
  'tool',
  'duration_ms',
  'approval',
  'args',
  'forwarded',
  'context',
  'result',
  'error',
  'event_id',
  'conversation_id',
];

/// The events as CSV (RFC 4180). Spreadsheets run text that starts with
/// `=`, `+`, `-` or `@` as a formula, so such cells get a leading apostrophe.
String auditToCsv(Iterable<AuditEvent> events) {
  String cell(Object? value) {
    var text = value == null ? '' : '$value';
    if (RegExp(r'^[=+\-@\t\r]').hasMatch(text)) text = "'$text";
    final needsQuotes = text.contains(RegExp(r'[",\r\n]'));
    return needsQuotes ? '"${text.replaceAll('"', '""')}"' : text;
  }

  final rows = [
    _csvColumns.join(','),
    for (final e in events)
      [
        e.timestamp.toIso8601String(),
        e.kind.name,
        e.status.name,
        e.source.name,
        e.actor,
        e.serverName,
        e.toolName,
        e.durationMs,
        e.approval,
        e.args,
        e.forwarded,
        e.context,
        e.result,
        e.error,
        e.id,
        e.conversationId,
      ].map(cell).join(','),
  ];
  return '${rows.join('\r\n')}\r\n';
}
