import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Creates the HTTP clients used for MCP and OAuth traffic. Overridden in
/// tests to inject a mock.
final mcpHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => http.Client.new,
);
