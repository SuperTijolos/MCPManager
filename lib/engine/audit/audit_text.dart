import 'dart:convert';

final _cutMarker = RegExp(r'… \[truncated (\d+) (chars|more items)\]');

/// Parses a stored audit preview as JSON.
///
/// Older versions cut a long JSON text in the middle and appended a marker, so
/// it no longer parses. Those are repaired: the open string and brackets are
/// closed, keeping the marker inside the last string. Returns null for text
/// that is not a JSON object or array, or cannot be repaired.
Object? parsePreview(String text) {
  final t = text.trimLeft();
  if (!t.startsWith('{') && !t.startsWith('[')) return null;
  try {
    return jsonDecode(text);
  } catch (_) {
    return _repair(text);
  }
}

Object? _repair(String text) {
  final marker = _cutMarker.allMatches(text).lastOrNull;
  var body = marker != null && marker.end == text.trimRight().length
      ? text.substring(0, marker.start)
      : text;

  // Walk the text to see what is still open at the cut.
  final open = <String>[];
  var inString = false;
  var escaped = false;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
    } else if (c == '{' || c == '[') {
      open.add(c);
    } else if ((c == '}' || c == ']') && open.isNotEmpty) {
      open.removeLast();
    }
  }
  if (inString) {
    if (escaped) body = body.substring(0, body.length - 1);
    // A cut inside a \uXXXX escape cannot be completed.
    body = body.replaceFirst(RegExp(r'\\u[0-9a-fA-F]{0,3}$'), '');
  }

  final closers = [for (final c in open.reversed) c == '{' ? '}' : ']'].join();
  final suffix = inString ? '${marker == null ? '' : marker.group(0)}"' : '';

  for (final fix in ['', ',', ':']) {
    var attempt = '$body$suffix';
    if (!inString && fix.isNotEmpty) {
      attempt = attempt.trimRight();
      if (attempt.endsWith(fix)) {
        attempt = attempt.substring(0, attempt.length - 1);
      } else {
        continue;
      }
    }
    try {
      return jsonDecode('$attempt$closers');
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// Whether showing [value] as indented JSON would be hard to read: a long or
/// multi-line string (such as a file's contents) turns into one escaped line.
bool hasBulkText(Object? value) {
  if (value is String) return value.contains('\n') || value.length > 200;
  if (value is Map) return value.values.any(hasBulkText);
  if (value is List) return value.any(hasBulkText);
  return false;
}

/// [value] as plain, indented text: keys on their own line and multi-line
/// strings as real lines, which is what a person wants to read.
String readableValue(Object? value) {
  final out = <String>[];
  void emit(Object? v, int depth, {String? label}) {
    final pad = '  ' * depth;
    final head = label == null ? '' : '$label:';
    if (v is Map) {
      if (v.isEmpty) {
        out.add('$pad$head (none)'.trimRight());
        return;
      }
      if (label != null) out.add('$pad$head');
      for (final e in v.entries) {
        emit(e.value, label == null ? depth : depth + 1, label: '${e.key}');
      }
    } else if (v is List) {
      if (v.isEmpty) {
        out.add('$pad$head (none)'.trimRight());
        return;
      }
      if (label != null) out.add('$pad$head');
      final inner = label == null ? depth : depth + 1;
      for (final item in v) {
        if (item is Map || item is List) {
          out.add('${'  ' * inner}-');
          emit(item, inner + 1);
        } else {
          emit(item, inner, label: '-');
        }
      }
    } else if (v is String && v.contains('\n')) {
      out.add('$pad$head'.trimRight());
      for (final line in v.split('\n')) {
        out.add('$pad  $line'.trimRight());
      }
    } else {
      final text = v is String ? v : jsonEncode(v);
      if (label == '-') {
        out.add('$pad- $text');
      } else {
        out.add('$pad$head $text'.trimRight());
      }
    }
  }

  if (value is Map && value.isEmpty) return '(none)';
  emit(value, 0);
  return out.join('\n');
}

/// One short line describing a stored result: for JSON, `key: value` pairs
/// with long text replaced by its size; otherwise the text, flattened.
String summarizeResult(String text, {int max = 140}) {
  String cap(String s) => s.length > max ? '${s.substring(0, max)}…' : s;
  final parsed = parsePreview(text);
  if (parsed is List) {
    return cap('${parsed.length} item${parsed.length == 1 ? '' : 's'}');
  }
  if (parsed is! Map) return cap(text.replaceAll(RegExp(r'\s+'), ' ').trim());

  String show(Object? v) {
    if (v is String) {
      final cut = _cutMarker.firstMatch(v);
      final hidden = cut == null ? 0 : int.parse(cut.group(1)!);
      final shown = cut == null ? v.length : cut.start;
      final total = shown + hidden;
      // File contents and other bulk text are better described by size; a
      // path or a sentence is still worth reading.
      if (v.contains('\n') || total > 200) {
        return total >= 1000
            ? '${(total / 1000).toStringAsFixed(1)}k chars'
            : '$total chars';
      }
      return v.length > 90 ? '${v.substring(0, 90)}…' : v;
    }
    if (v is Map) return '{${v.length}}';
    if (v is List) return '[${v.length}]';
    return '$v';
  }

  final parts = [for (final e in parsed.entries) '${e.key}: ${show(e.value)}'];
  return cap(parts.isEmpty ? '(empty)' : parts.join(' · '));
}
