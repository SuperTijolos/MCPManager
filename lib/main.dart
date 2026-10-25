import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine/core/env.dart';
import 'engine/core/prefs.dart';
import 'engine/server/session.dart';
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

class MCPManagerApp extends ConsumerStatefulWidget {
  const MCPManagerApp({super.key});

  @override
  ConsumerState<MCPManagerApp> createState() => _MCPManagerAppState();
}

class _MCPManagerAppState extends ConsumerState<MCPManagerApp> {
  // Tells the router to look again when someone signs in or out.
  final _sessionChanged = ValueNotifier<int>(0);
  late final _router = createRouter(
    signedIn: () => ref.read(sessionProvider).signedIn,
    refresh: _sessionChanged,
  );

  @override
  void initState() {
    super.initState();
    ref.listenManual(sessionProvider, (previous, next) {
      if (previous?.status != next.status) _sessionChanged.value++;
    });
  }

  @override
  void dispose() {
    _router.dispose();
    _sessionChanged.dispose();
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
