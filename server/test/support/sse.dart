import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SseMessage {
  SseMessage(this.event, this.data);
  final String event;
  final Map<String, dynamic> data;
  @override
  String toString() => '$event $data';
}

/// Reads a Server-Sent Events stream, one message at a time.
class SseReader {
  SseReader._(this.status, this.headers, this._client, this._sub);

  final int status;
  final Map<String, String> headers;
  final http.Client _client;
  final StreamSubscription<String> _sub;
  final messages = <SseMessage>[];
  final comments = <String>[];
  var _read = 0;
  var done = false;
  Completer<void>? _wake;

  static Future<SseReader> open(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final client = http.Client();
    final response = await client.send(
      http.Request('GET', Uri.parse(url))..headers.addAll(headers),
    );
    late SseReader reader;
    var event = 'message';
    final data = StringBuffer();
    final sub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.isEmpty) {
              if (data.isNotEmpty) {
                reader.messages.add(
                  SseMessage(
                    event,
                    (jsonDecode(data.toString()) as Map)
                        .cast<String, dynamic>(),
                  ),
                );
              }
              event = 'message';
              data.clear();
            } else if (line.startsWith(':')) {
              reader.comments.add(line);
            } else if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              data.write(line.substring(5).trim());
            }
            reader._poke();
          },
          onDone: () {
            reader.done = true;
            reader._poke();
          },
          onError: (_) {
            reader.done = true;
            reader._poke();
          },
        );
    reader = SseReader._(response.statusCode, response.headers, client, sub);
    return reader;
  }

  void _poke() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// The next message not yet returned.
  Future<SseMessage> next({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final end = DateTime.now().add(timeout);
    while (_read >= messages.length) {
      if (done) throw StateError('stream ended');
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no message', timeout);
      _wake = Completer<void>();
      await _wake!.future.timeout(left, onTimeout: () {});
    }
    return messages[_read++];
  }

  /// The next message of [event], skipping others.
  Future<SseMessage> nextOf(String event) async {
    while (true) {
      final m = await next();
      if (m.event == event) return m;
    }
  }

  /// Whether nothing else arrives within [wait].
  Future<bool> quietFor([
    Duration wait = const Duration(milliseconds: 250),
  ]) async {
    await Future<void>.delayed(wait);
    return _read >= messages.length;
  }

  Future<void> close() async {
    await _sub.cancel();
    _client.close();
  }
}
