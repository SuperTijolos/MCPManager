import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';

typedef FileDownloader = bool Function(
  String filename,
  String content, {
  String mime,
});

/// Saves a text file in the browser. Tests replace it to capture the file.
final fileDownloadProvider = Provider<FileDownloader>(
  (ref) => downloadTextFile,
);
