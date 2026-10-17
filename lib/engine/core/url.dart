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

final _hostName = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$');

bool isValidHttpUrl(String input) {
  if (input.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(input);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final host = uri.host;
  if (host.isEmpty) return false;
  // Dart's parser tolerates odd characters in hosts; accept only real
  // hostnames, IPv4 addresses and IPv6 literals.
  return host.contains(':') || _hostName.hasMatch(host);
}
