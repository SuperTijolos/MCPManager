import 'package:flutter/material.dart';

import '../../../ui/widgets.dart';

class ContributorsPage extends StatelessWidget {
  const ContributorsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageScaffold(
      title: 'Contributors',
      subtitle: 'SuperTijolos / MCPManager',
      child: ListTile(
        leading: CircleAvatar(child: Icon(Icons.person)),
        title: Text('GuikiPT'),
        subtitle: Text('Flutter rewrite'),
      ),
    );
  }
}
