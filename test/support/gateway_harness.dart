import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_portal_server/mcp_portal_server.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'fakes.dart';

const gatewayUrl = 'http://gateway.test';
const gatewayAdminToken = 'admin-token-for-app-tests-123';

/// The real gateway, in memory, reachable through an [http.Client] that calls
/// its request handler directly: no sockets, so widget tests can use it.
class TestGateway {
  TestGateway._(this.server, this.client);

  final GatewayServer server;

  /// What the app uses to talk to the gateway.
  final http.Client client;

  /// The gateway's own state, to check what the app really did.
  PortalState get state => server.store.state;

  /// [upstream] is what the gateway's servers answer with; every server
  /// behind it shares that one fake.
  ///
  /// [upstreamClient] replaces that fake with any client, for example one that
  /// always fails.
  static Future<TestGateway> start({
    FakeMcpServer? upstream,
    http.Client Function()? upstreamClient,
  }) async {
    final server = await GatewayServer.create(
      GatewayConfig(adminToken: gatewayAdminToken, publicBaseUrl: gatewayUrl),
      upstreamClient:
          upstreamClient ?? () => (upstream ?? FakeMcpServer()).client,
      inMemory: true,
    );
    final client = MockClient.streaming((request, body) async {
      final bytes = await body.toBytes();
      final response = await server.handler(
        shelf.Request(
          request.method,
          request.url,
          headers: request.headers,
          body: bytes,
        ),
      );
      return http.StreamedResponse(
        response.read(),
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    });
    return TestGateway._(server, client);
  }

  Future<void> close() async {
    client.close();
    await server.close();
  }
}
