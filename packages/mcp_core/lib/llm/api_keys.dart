/// Accept raw credentials, quoted credentials, or Bearer-prefixed values.
/// Users sometimes paste the whole header, twice. Never include the prefix
/// more than once in an outgoing Authorization header.
String normalizeApiKey(String? value) {
  var key = (value ?? '').trim();
  for (var i = 0; i < 4; i++) {
    if (key.length >= 2 &&
        ((key.startsWith('"') && key.endsWith('"')) ||
            (key.startsWith("'") && key.endsWith("'")))) {
      key = key.substring(1, key.length - 1).trim();
      continue;
    }
    final bearer = RegExp(r'^Bearer\s+', caseSensitive: false).firstMatch(key);
    if (bearer == null) break;
    key = key.substring(bearer.end).trim();
  }
  return key;
}

/// OpenRouter rejects malformed Bearer tokens with a misleading 401 error:
/// "Missing Authentication header", even if a header was sent. Validate the
/// documented key prefix locally without exposing or transmitting the value.
String? openRouterKeyProblem(String? value) {
  final key = normalizeApiKey(value);
  if (key.isEmpty) return 'OpenRouter requires an API key.';
  if (!key.startsWith('sk-or-v1-')) {
    return 'This is not an OpenRouter API key. OpenRouter keys start with '
        'sk-or-v1-. Copy one from your OpenRouter Keys page.';
  }
  // A standard OpenRouter API key contains exactly 64 lowercase hex digits
  // after the prefix. A truncated or redacted value can otherwise produce a
  // misleading "Missing Authentication header" response from OpenRouter.
  if (!RegExp(r'^sk-or-v1-[0-9a-f]{64}$').hasMatch(key)) {
    return 'Invalid OpenRouter API key format. A complete key starts with '
        'sk-or-v1- followed by 64 lowercase hexadecimal characters. '
        'Copy the full key from OpenRouter (do not paste a masked key).';
  }
  return null;
}
