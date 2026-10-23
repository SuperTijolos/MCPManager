import 'dart:async';
import 'dart:io';

import 'package:mcp_portal_server/mcp_portal_server.dart';

Future<void> main(List<String> args) async {
  final config = GatewayConfig.fromEnvironment();
  final GatewayServer gateway;
  try {
    gateway = await GatewayServer.create(config);
  } on ArgumentError catch (e) {
    stderr.writeln('Cannot start: ${e.message}');
    exit(64);
  } on Object catch (e) {
    stderr.writeln('Cannot start: $e');
    exit(69);
  }
  final server = await gateway.start();

  final base =
      config.publicBaseUrl ?? 'http://${server.address.host}:${server.port}';
  stdout
    ..writeln('MCP portal gateway $gatewayVersion listening on $base')
    ..writeln('Database connected, migrations applied.');
  final token = gateway.generatedAdminToken;
  if (token != null) {
    stdout
      ..writeln()
      ..writeln('First start: your admin token is')
      ..writeln('  $token')
      ..writeln(
        'It is shown only now. Keep it somewhere safe; to choose your own, set PORTAL_ADMIN_TOKEN.',
      )
      ..writeln();
  } else if (config.adminToken == null) {
    stdout.writeln(
      'Admin token: the one shown at first start (set PORTAL_ADMIN_TOKEN to replace it).',
    );
  }

  // Close cleanly on Ctrl+C / docker stop so the audit log is flushed.
  final done = Completer<void>();
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  stdout.writeln('Shutting down…');
  await gateway.close();
}
