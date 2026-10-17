/// Parses `Name: value` lines into a header map; blank lines are ignored.
/// Returns null (and the offending line via [onError]) for malformed input.
Map<String, String>? parseHeaderLines(
  String text, {
  void Function(String line)? onError,
}) {
  final headers = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) {
      onError?.call(line);
      return null;
    }
    headers[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  return headers;
}

String formatHeaderLines(Map<String, String> headers) =>
    headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
