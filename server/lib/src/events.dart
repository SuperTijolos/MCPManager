import 'dart:async';
import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';

import 'audit.dart';

/// Something the dashboard may want to know about as it happens.
class GatewayEvent {
  GatewayEvent(this.type, this.data);

  /// `audit` (a call was recorded), `changed` (stored settings changed, with
  /// the names of what changed), `health` (an upstream server went up or down)
  /// or `chat` (a conversation changed).
  final String type;
  final Json data;

  /// One Server-Sent Events message.
  String encode(int id) =>
      'id: $id\nevent: $type\ndata: ${jsonEncode(data)}\n\n';
}

/// Fans events out to every open dashboard stream.
class EventBus {
  final _controller = StreamController<GatewayEvent>.broadcast(sync: true);

  Stream<GatewayEvent> get stream => _controller.stream;
  bool get hasListeners => _controller.hasListener;

  void emit(String type, Json data) {
    if (_controller.isClosed) return;
    _controller.add(GatewayEvent(type, data));
  }

  Future<void> close() => _controller.close();
}

/// An audit log that announces each event after it is stored.
class BroadcastAuditLog implements GatewayAuditLog {
  BroadcastAuditLog(this.inner, this.bus);

  final GatewayAuditLog inner;
  final EventBus bus;

  @override
  Future<void> record(GatewayAuditEvent event) async {
    await inner.record(event);
    bus.emit('audit', event.toJson());
  }

  @override
  Future<List<GatewayAuditEvent>> recent({
    int limit = 100,
    String? portalId,
    String? status,
    String? query,
    String? source,
    String? conversationId,
  }) => inner.recent(
    limit: limit,
    portalId: portalId,
    status: status,
    query: query,
    source: source,
    conversationId: conversationId,
  );

  @override
  Future<int> delete({
    List<String>? ids,
    DateTime? before,
    bool all = false,
  }) async {
    final removed = await inner.delete(ids: ids, before: before, all: all);
    if (removed > 0) bus.emit('audit-deleted', {'count': removed});
    return removed;
  }

  @override
  Future<void> flush() => inner.flush();
}
