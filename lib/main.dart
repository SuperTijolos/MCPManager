import 'package:flutter/material.dart';
import 'package:mcp_manager/router/routes.dart';

void main() {
  runApp(const MCPManagerApp());
}

class MCPManagerApp extends StatelessWidget {
  const MCPManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Flutter Demo',
      theme: ThemeData.dark(),
      routerConfig: mcpManagerRouter,
    );
  }
}

