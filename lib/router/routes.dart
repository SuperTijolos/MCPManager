import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final mcpManagerRouter = GoRouter(routes: [
  GoRoute(path: '/', name: 'Home', builder: (context, state) => Placeholder(),),
  GoRoute(path: '/contributors', name: 'Contributors', builder: (context, state) => Placeholder(),),
]);