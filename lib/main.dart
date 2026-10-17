import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine/core/env.dart';
import 'engine/core/prefs.dart';
import 'router/routes.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = await AppEnv.load();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appEnvProvider.overrideWithValue(env),
      ],
      child: const MCPManagerApp(),
    ),
  );
}

class MCPManagerApp extends StatefulWidget {
  const MCPManagerApp({super.key});

  @override
  State<MCPManagerApp> createState() => _MCPManagerAppState();
}

class _MCPManagerAppState extends State<MCPManagerApp> {
  final _router = createRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MCP Manager',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: _router,
    );
  }
}
