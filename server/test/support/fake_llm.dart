import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SeenRequest {
  SeenRequest(this.method, this.path, this.query, this.headers, this.body);
  final String method;
  final String path;
  final String query;
  final Map<String, String> headers;
  final String body;
}

/// A language-model endpoint (OpenAI-style paths) that records what it gets
/// and can stream slowly.
class FakeLlm {
  FakeLlm._(this._server);

  final HttpServer _server;
  final requests = <SeenRequest>[];

  /// Completes when writing to the client fails: it went away.
  final disconnected = Completer<void>();

  /// A streamed reply waits for this before sending its second half.
  Completer<void> gate = Completer<void>();

  String get origin => 'http://127.0.0.1:${_server.port}';
  String get v1 => '$origin/v1';

  static Future<FakeLlm> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeLlm._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((n, v) => headers[n] = v.join(','));
    requests.add(
      SeenRequest(
        request.method,
        request.uri.path,
        request.uri.query,
        headers,
        body,
      ),
    );
    final response = request.response;

    switch (request.uri.path) {
      case '/v1/models':
        response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'model-a'},
              ],
            }),
          );
        await response.close();
      case '/v1/chat/completions':
        // A raw socket, because dart:io swallows writes to a closed
        // connection but does report the peer closing it.
        final socket = await response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onError: (_) {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          cancelOnError: true,
        );
        void send(String text) => socket.add(utf8.encode(text));
        send(
          'HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n'
          'connection: close\r\n\r\n',
        );
        send('data: {"first":true}\n\n');
        await socket.flush();
        await gate.future;
        try {
          for (var i = 0; i < 300 && !disconnected.isCompleted; i++) {
            send('data: {"n":$i}\n\n');
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          if (!disconnected.isCompleted) {
            send('data: [DONE]\n\n');
            await socket.flush();
            await socket.close();
          }
        } catch (_) {
          if (!disconnected.isCompleted) disconnected.complete();
        }
      case '/v1/unauthorized':
        response
          ..statusCode = 401
          ..headers.contentType = ContentType.json
          ..write('{"error":"bad key"}');
        await response.close();
      default:
        response
          ..statusCode = 404
          ..write('nothing here');
        await response.close();
    }
  }
}
