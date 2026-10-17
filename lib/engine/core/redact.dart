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

/// Redacted, size-limited JSON string suitable for storing in the audit log.
String redactedPreview(Object? value, {int max = 2000}) {
  if (value is String) return truncate(redactText(value), max);
  try {
    return truncate(jsonEncode(redact(value)), max);
  } catch (_) {
    return truncate(redactText('$value'), max);
  }
}
