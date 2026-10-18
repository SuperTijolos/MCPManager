/// Without a browser there is nothing to download to; callers fall back to
/// copying.
bool downloadTextFile(
  String filename,
  String content, {
  String mime = 'text/plain',
}) => false;
