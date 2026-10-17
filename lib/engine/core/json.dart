import 'dart:convert';

typedef Json = Map<String, dynamic>;

const _encoder = JsonEncoder.withIndent('  ');

String prettyJson(Object? value) {
  try {
    return _encoder.convert(value);
  } catch (_) {
    return value.toString();
  }
}

/// Decodes [source] into a JSON object, or returns null when it is not one.
Json? tryDecodeObject(String source) {
  try {
    final decoded = jsonDecode(source);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Decodes [text] when it looks like a JSON object or array, otherwise null.
Object? tryDecodeJson(String text) {
  final t = text.trimLeft();
  if (!(t.startsWith('{') || t.startsWith('['))) return null;
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

String truncate(String text, int max) {
  if (text.length <= max) return text;
  return '${text.substring(0, max)}… [truncated ${text.length - max} chars]';
}
