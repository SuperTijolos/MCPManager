import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Saves [content] as a file through the browser's download mechanism.
bool downloadTextFile(
  String filename,
  String content, {
  String mime = 'text/plain',
}) {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: '$mime;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final link = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  web.document.body!.append(link);
  link.click();
  link.remove();
  web.URL.revokeObjectURL(url);
  return true;
}
