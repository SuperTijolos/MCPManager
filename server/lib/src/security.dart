import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

/// SHA-256 of a secret, hex encoded. Secrets are long random values, so a
/// plain hash is enough to store them.
String hashSecret(String secret) =>
    sha256.convert(utf8.encode(secret)).toString();

/// [bytes] random bytes, URL-safe base64 without padding.
String randomSecret({String prefix = '', int bytes = 32}) {
  final data = List<int>.generate(bytes, (_) => _random.nextInt(256));
  return '$prefix${base64Url.encode(data).replaceAll('=', '')}';
}

/// Compares in time that does not depend on where the texts differ.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// The token of an `Authorization: Bearer …` header, or null.
String? bearerToken(String? header) {
  if (header == null) return null;
  final match = RegExp(
    r'^Bearer\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(header.trim());
  final token = match?.group(1)?.trim();
  return token == null || token.isEmpty ? null : token;
}

/// RFC 7636 S256: base64url(SHA-256(verifier)) without padding.
String pkceS256(String verifier) => base64Url
    .encode(sha256.convert(utf8.encode(verifier)).bytes)
    .replaceAll('=', '');
