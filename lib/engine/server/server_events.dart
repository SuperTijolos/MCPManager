import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_client.dart';
import 'session.dart';

/// Turns the live stream off (tests), or on. The stream reconnects by itself
/// and uses a timer while it waits, which test frameworks dislike.
final serverEventsEnabledProvider = Provider<bool>((ref) => true);

/// What the server pushes, as one stream that survives reconnects. A `ready`
/// event arrives each time the connection is (re)established: listeners
/// reload what they show then, because nothing is replayed.
class ServerEventStream {
  ServerEventStream(this._client, {this.retryAfter});

  final ServerClient _client;
  final Duration? retryAfter;
  final _controller = StreamController<ServerEvent>.broadcast();
  var _closed = false;
  var _failures = 0;

  Stream<ServerEvent> get stream => _controller.stream;

  void start() => unawaited(_run());

  Future<void> _run() async {
    while (!_closed) {
      try {
        await for (final e in _client.events()) {
          if (_closed) return;
          _failures = 0;
          _controller.add(e);
        }
      } on ServerException catch (e) {
        if (e.unauthorized) return;
      } catch (_) {
        // A dropped connection: fall through to the retry.
      }
      if (_closed) return;
      _failures++;
      final wait =
          retryAfter ??
          Duration(seconds: (1 << (_failures - 1).clamp(0, 4)).clamp(1, 15));
      await Future<void>.delayed(wait);
    }
  }

  void close() {
    _closed = true;
    _controller.close();
  }
}

/// The live events of the signed-in server, or null when signed out.
final serverEventsProvider = Provider<ServerEventStream?>((ref) {
  final client = ref.watch(serverClientProvider);
  if (client == null || !ref.watch(serverEventsEnabledProvider)) return null;
  final events = ServerEventStream(client)..start();
  ref.onDispose(events.close);
  return events;
});

/// Calls [onEvent] for each event of the signed-in server until [ref] is
/// disposed. Safe to call when the stream is off.
void listenToServer(Ref ref, void Function(ServerEvent event) onEvent) {
  final events = ref.watch(serverEventsProvider);
  if (events == null) return;
  final sub = events.stream.listen(onEvent);
  ref.onDispose(sub.cancel);
}
