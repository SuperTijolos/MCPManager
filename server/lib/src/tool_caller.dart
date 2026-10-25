import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';

import 'access.dart';
import 'audit.dart';
import 'models.dart';
import 'upstream.dart';

/// What came of one tool call.
class CallOutcome {
  const CallOutcome({
    required this.status,
    this.result,
    this.rejected,
    this.upstreamError,
    this.durationMs,
    this.event,
  });

  /// `success`, `error` or `denied`, as recorded.
  final String status;

  /// The server's answer, when it gave one (it may still be an error result).
  final McpToolResult? result;

  /// Why the call was refused before it left the gateway (a rule's required
  /// argument was missing, for instance).
  final String? rejected;

  /// Why the server could not be reached or failed outright.
  final String? upstreamError;
  final int? durationMs;

  /// What was written to the audit log for this call.
  final GatewayAuditEvent? event;
}

/// Applies the rules to a call, forwards it to the upstream server and writes
/// it to the audit log. Portal clients, the dashboard's test bench and its
/// chat all go through here, so every call is judged and recorded the same way.
class ToolCaller {
  ToolCaller({
    required this.pool,
    required this.audit,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final UpstreamPool pool;
  final GatewayAuditLog audit;
  final DateTime Function() _now;

  /// Never throws: a failure is in the outcome (and the audit log).
  Future<CallOutcome> run({
    required UpstreamServer server,
    required String toolName,
    required EffectiveTool effective,
    required Json args,
    required Principal who,
    String source = 'portal',
    Portal? portal,
    String? exposedName,
    String? conversationId,
    String? actor,
    String? approval,
  }) async {
    Future<GatewayAuditEvent> record(
      String status, {
      Json? forwarded,
      Json? context,
      String? result,
      String? error,
      int? durationMs,
    }) => this.record(
      status: status,
      who: who,
      source: source,
      portal: portal,
      server: server,
      tool: toolName,
      exposedName: exposedName,
      args: args,
      rules: effective.rules,
      forwarded: forwarded,
      context: context,
      result: result,
      error: error,
      durationMs: durationMs,
      conversationId: conversationId,
      actor: actor,
      approval: approval,
    );

    final prepared = prepareCall(effective, args);
    if (prepared.error != null) {
      final event = await record(
        'error',
        error: 'Rejected before forwarding: ${prepared.error}',
      );
      return CallOutcome(
        status: 'error',
        rejected: prepared.error,
        event: event,
      );
    }

    final watch = Stopwatch()..start();
    try {
      final result = await pool.call(server, toolName, prepared.forwarded);
      watch.stop();
      final status = result.isError ? 'error' : 'success';
      final event = await record(
        status,
        forwarded: prepared.forwarded,
        context: prepared.context,
        result: result.text,
        error: result.isError ? result.text : null,
        durationMs: watch.elapsedMilliseconds,
      );
      return CallOutcome(
        status: status,
        result: result,
        durationMs: watch.elapsedMilliseconds,
        event: event,
      );
    } catch (e) {
      watch.stop();
      final message = e is McpException ? e.message : '$e';
      final event = await record(
        'error',
        forwarded: prepared.forwarded,
        context: prepared.context,
        error: message,
        durationMs: watch.elapsedMilliseconds,
      );
      return CallOutcome(
        status: 'error',
        upstreamError: message,
        durationMs: watch.elapsedMilliseconds,
        event: event,
      );
    }
  }

  /// Writes one audit event (arguments and results masked and shortened) and
  /// returns it.
  Future<GatewayAuditEvent> record({
    required String status,
    required Principal who,
    required Json args,
    String source = 'portal',
    Portal? portal,
    UpstreamServer? server,
    String? tool,
    String? exposedName,
    List<String> rules = const [],
    Json? forwarded,
    Json? context,
    String? result,
    String? error,
    int? durationMs,
    String? conversationId,
    String kind = 'toolCall',
    String? actor,
    String? approval,
  }) async {
    final argsPreview = redactedPreview(args);
    final forwardedPreview =
        forwarded != null && jsonEncode(forwarded) != jsonEncode(args)
        ? redactedPreview(forwarded)
        : null;
    final event = GatewayAuditEvent(
      id: newId('evt'),
      timestamp: _now(),
      source: source,
      portalId: portal?.id,
      portalSlug: portal?.slug,
      principal: who.toJson(),
      status: status,
      serverId: server?.id,
      serverName: server?.name,
      tool: tool,
      exposedName: exposedName,
      durationMs: durationMs,
      args: argsPreview,
      forwarded: forwardedPreview,
      context: context == null || context.isEmpty
          ? null
          : redactedPreview(context),
      result: result == null ? null : redactedPreview(result),
      error: error == null ? null : redactText(error),
      rules: rules,
      conversationId: conversationId,
      kind: kind,
      actor: actor,
      approval: approval,
    );
    await audit.record(event);
    return event;
  }
}
