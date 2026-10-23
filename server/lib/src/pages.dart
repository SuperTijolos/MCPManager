import 'package:shelf/shelf.dart';

/// A page for the browser. [redirect] is where the form will end up sending
/// the user, so the policy can allow exactly that destination and no other.
Response htmlResponse(int status, String body, {String? redirect}) {
  var allowed = "'self'";
  final uri = redirect == null ? null : Uri.tryParse(redirect);
  if (uri != null && uri.hasScheme) {
    final web = uri.scheme == 'https' || uri.scheme == 'http';
    allowed += web ? ' ${uri.origin}' : ' ${uri.scheme}:';
  }
  return Response(
    status,
    body: body,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'x-frame-options': 'DENY',
      'content-security-policy':
          "default-src 'none'; style-src 'unsafe-inline'; form-action $allowed; frame-ancestors 'none'",
      'referrer-policy': 'no-referrer',
    },
  );
}

String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String htmlPage(String title, String body) =>
    '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title</title>
<style>
body{font:16px/1.5 system-ui,sans-serif;background:#0f1419;color:#e6edf3;margin:0;display:grid;place-items:center;min-height:100vh}
main{max-width:420px;width:100%;padding:28px;background:#1a212a;border-radius:14px;margin:16px}
h1{font-size:20px;margin:0 0 12px}
label{display:block;margin:16px 0 8px;font-size:14px;color:#9fb0c0}
input{width:100%;box-sizing:border-box;padding:10px 12px;border-radius:8px;border:1px solid #33404d;background:#0f1419;color:inherit;font-size:16px}
.row{display:flex;gap:10px;margin-top:18px}
button{flex:1;padding:10px;border:0;border-radius:8px;background:#5fd4c4;color:#04201b;font-size:16px;font-weight:600;cursor:pointer}
a.button{display:block;text-align:center;padding:10px;border-radius:8px;background:#5fd4c4;color:#04201b;font-weight:600;text-decoration:none}
button.secondary{background:#2a3541;color:#e6edf3}
.error{color:#ff8a80}.hint{font-size:13px;color:#8a99a8;margin-top:18px}
</style></head><body><main><h1>$title</h1>$body</main></body></html>''';
