/// Turns user/`.env` input such as `100.64.0.1:11434 # tailscale` or
/// `localhost:11434/` into `http://100.64.0.1:11434`.
String normalizeBaseUrl(String input) {
  var url = input.trim();
  final comment = url.indexOf(RegExp(r'\s#'));
  if (comment != -1) url = url.substring(0, comment).trim();
  if (url.isEmpty) return '';
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
    url = 'http://$url';
  }
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

bool isValidHttpUrl(String input) {
  final uri = Uri.tryParse(input);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}
