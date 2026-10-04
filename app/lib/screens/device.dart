import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/native.dart';
import '../state/auth.dart';
import '../widgets/common.dart';

/// Android: who is signed in, where, and the widget controls.
class DeviceScreen extends ConsumerWidget {
  const DeviceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).value;
    if (auth is! SignedIn) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: const Text('Device')),
      body: Centered(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(auth.user.username),
              subtitle: const Text('Signed in'),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(auth.serverUrl),
              subtitle: const Text('Server'),
            ),
            const SectionTitle('Widget'),
            const ListTile(
              leading: Icon(Icons.widgets_outlined),
              title: Text('Add the widget to your home screen'),
              subtitle: Text(
                'Long-press an empty spot on the home screen, choose Widgets, and pick HaBytes. '
                'Tap a habit there to log it, even offline.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Refresh widget'),
              onTap: () async {
                await Native.refreshWidgets();
                if (context.mounted) showMessage(context, 'Widget refreshed');
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: ref.read(authProvider.notifier).signOut,
            ),
          ],
        ),
      ),
    );
  }
}
