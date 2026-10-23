import 'dart:convert';

import 'json.dart';

const redacted = '[redacted]';

final _secretKey = RegExp(
  r'(pass(word|wd)?|secret|token|api[-_]?key|authorization|cookie|bearer|private[-_]?key|credential|session[-_]?id)',
  caseSensitive: false,
);

final _secretInText = <RegExp>[
  RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(r'\bsk-[A-Za-z0-9_-]{16,}'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
  RegExp(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
];

/// Returns a deep copy of [value] with secret-looking keys and token-looking
/// strings masked. Audit records and LLM-visible summaries go through this.
Object? redact(Object? value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        '${e.key}': _secretKey.hasMatch('${e.key}')
            ? redacted
            : redact(e.value),
    };
  }
  if (value is List) return [for (final v in value) redact(v)];
  if (value is String) return redactText(value);
  return value;
}

String redactText(String text) {
  var out = text;
  for (final pattern in _secretInText) {
    out = out.replaceAll(pattern, redacted);
  }
  return out;
}

/// Redacted, size-limited text for the audit log.
///
/// JSON stays JSON: objects and arrays (also when they arrive as a string, as
/// tool results do) are redacted by key name, and when too long it is the
/// long strings and lists inside that get shortened, so the stored preview can
/// still be parsed and shown indented. Anything else is plain text, masked by
/// pattern and cut at [max].
String redactedPreview(Object? value, {int max = 2000}) {
  Object? data = value;
  if (value is String) {
    final decoded = _tryJsonContainer(value);
    if (decoded == null) return truncate(redactText(value), max);
    data = decoded;
  }
  try {
    return _fit(redact(data), max);
  } catch (_) {
    return truncate(redactText('$value'), max);
  }
}

Object? _tryJsonContainer(String text) {
  final t = text.trimLeft();
  if (!t.startsWith('{') && !t.startsWith('[')) return null;
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

String _fit(Object? value, int max) {
  var text = jsonEncode(value);
  if (text.length <= max) return text;
  for (var limit = 1000; limit >= 32; limit ~/= 2) {
    text = jsonEncode(_shrink(value, limit));
    if (text.length <= max) return text;
  }
  return truncate(text, max);
}

/// A copy with strings cut to [limit] characters and long lists cut to 20.
Object? _shrink(Object? value, int limit) {
  if (value is String && value.length > limit) {
    return '${value.substring(0, limit)}… '
        '[truncated ${value.length - limit} chars]';
  }
  if (value is Map) {
    return {for (final e in value.entries) '${e.key}': _shrink(e.value, limit)};
  }
  if (value is List) {
    const keep = 20;
    return [
      for (final v in value.take(keep)) _shrink(v, limit),
      if (value.length > keep)
        '… [truncated ${value.length - keep} more items]',
    ];
  }
  return value;
}

/// Whether a stored preview was shortened to fit (see [redactedPreview]).
bool previewWasShortened(String text) =>
    RegExp(r'… \[truncated \d+ (chars|more items)\]').hasMatch(text);
