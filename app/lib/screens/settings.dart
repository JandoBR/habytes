import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../platform/browser.dart';
import '../platform/native.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../widgets/common.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Centered(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const SectionTitle('Calendar'),
            ListTile(
              title: const Text('Time zone'),
              subtitle: Text(user.timezone),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editTimeZone(context, ref, user),
            ),
            ListTile(
              title: const Text('First day of the week'),
              trailing: DropdownButton<int>(
                value: user.weekStart,
                underline: const SizedBox.shrink(),
                items: [
                  for (var day = 1; day <= 7; day++)
                    DropdownMenuItem(value: day, child: Text(weekdayNames[day - 1])),
                ],
                onChanged: (day) => guard(context, () async {
                  final updated = await ref.read(apiProvider).updateMe(weekStart: day);
                  ref.read(authProvider.notifier).setUser(updated);
                  ref.invalidate(todayProvider);
                  Native.refreshWidgets();
                }),
              ),
            ),
            const SectionTitle('Webhooks'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'A POST request to a habit\'s webhook URL logs it for today: one more for a '
                'counter (or ?delta=N), checked for a yes/no habit.',
              ),
            ),
            const _Webhooks(),
            const SectionTitle('API tokens'),
            const _Tokens(api: true),
            const SectionTitle('Signed-in devices and sessions'),
            const _Tokens(api: false),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              subtitle: Text(user.username),
              onTap: ref.read(authProvider.notifier).signOut,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editTimeZone(BuildContext context, WidgetRef ref, User user) async {
    final deviceZone = kIsWeb ? browserTimeZone() : await Native.timeZone();
    if (!context.mounted) return;
    final controller = TextEditingController(text: user.timezone);
    final zone = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Time zone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'IANA name',
                hintText: 'America/Bogota',
              ),
            ),
            if (deviceZone != null)
              TextButton(
                onPressed: () => controller.text = deviceZone,
                child: Text('Use this device\'s: $deviceZone'),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (zone == null || zone.isEmpty || zone == user.timezone || !context.mounted) return;
    await guard(context, () async {
      final updated = await ref.read(apiProvider).updateMe(timezone: zone);
      ref.read(authProvider.notifier).setUser(updated);
    });
  }
}

class _Webhooks extends ConsumerWidget {
  const _Webhooks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiProvider);

    Future<void> run(Future<void> Function() action, String done) async {
      if (await guard(context, action)) {
        ref.invalidate(habitsProvider);
        if (context.mounted) showMessage(context, done);
      }
    }

    Future<void> copy(String url) async {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) showMessage(context, 'Webhook URL copied');
    }

    return AsyncView(
      value: ref.watch(habitsProvider),
      onRetry: () => ref.invalidate(habitsProvider),
      builder: (habits) {
        final active = habits.where((h) => !h.archived).toList();
        if (active.isEmpty) {
          return const ListTile(title: Text('No habits yet.'));
        }
        return Column(
          children: [
            for (final habit in active)
              ListTile(
                title: Text(habit.name),
                subtitle: Text(
                  habit.webhookUrl ?? 'No webhook',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: habit.webhookUrl == null ? null : () => copy(habit.webhookUrl!),
                trailing: habit.webhookUrl == null
                    ? TextButton(
                        onPressed: () => run(() => api.createWebhook(habit.id), 'Webhook created'),
                        child: const Text('Create'),
                      )
                    : PopupMenuButton<String>(
                        onSelected: (action) async {
                          switch (action) {
                            case 'copy':
                              await copy(habit.webhookUrl!);
                            case 'rotate':
                              final ok = await confirm(
                                context,
                                title: 'Rotate webhook?',
                                message: 'The current URL for "${habit.name}" will stop working.',
                                action: 'Rotate',
                              );
                              if (ok) await run(() => api.createWebhook(habit.id), 'Webhook rotated');
                            case 'disable':
                              await run(() => api.deleteWebhook(habit.id), 'Webhook disabled');
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'copy', child: Text('Copy URL')),
                          PopupMenuItem(value: 'rotate', child: Text('Rotate')),
                          PopupMenuItem(value: 'disable', child: Text('Disable')),
                        ],
                      ),
              ),
          ],
        );
      },
    );
  }
}

String _ago(DateTime? time) {
  if (time == null) return 'never used';
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 2) return 'used just now';
  if (elapsed.inHours < 1) return 'used ${elapsed.inMinutes} minutes ago';
  if (elapsed.inDays < 1) return 'used ${elapsed.inHours} hours ago';
  return 'used ${elapsed.inDays} days ago';
}

/// API tokens ([api] true) or sessions and devices ([api] false).
class _Tokens extends ConsumerWidget {
  const _Tokens({required this.api});

  final bool api;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> revoke(TokenInfo token) async {
      final ok = await confirm(
        context,
        title: 'Revoke "${token.name}"?',
        message: token.current
            ? 'This is the credential you are using now; you will be signed out.'
            : 'Whatever is using it will lose access.',
        action: 'Revoke',
      );
      if (!ok || !context.mounted) return;
      await guard(context, () => ref.read(apiProvider).revokeToken(token.id));
      ref.invalidate(tokensProvider);
    }

    Future<void> create() async {
      final request = await showDialog<({String name, int? days})>(
        context: context,
        builder: (context) => const _NewTokenDialog(),
      );
      if (request == null || !context.mounted) return;
      String? secret;
      await guard(context, () async {
        secret = await ref.read(apiProvider).createToken(request.name, expiresInDays: request.days);
      });
      ref.invalidate(tokensProvider);
      if (secret == null || !context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Copy your token'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('It will not be shown again.'),
              const SizedBox(height: 12),
              SelectableText(secret!, style: const TextStyle(fontFamily: 'monospace')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: secret!)),
              child: const Text('Copy'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        ),
      );
    }

    return AsyncView(
      value: ref.watch(tokensProvider),
      onRetry: () => ref.invalidate(tokensProvider),
      builder: (tokens) {
        final shown = tokens.where((t) => (t.kind == 'api') == api).toList();
        return Column(
          children: [
            for (final token in shown)
              ListTile(
                leading: Icon(switch (token.kind) {
                  'session' => Icons.language,
                  'device' => Icons.phone_android,
                  _ => Icons.key,
                }),
                title: Text(token.current ? '${token.name} (this one)' : token.name),
                subtitle: Text(
                  [
                    _ago(token.lastUsedAt),
                    if (token.expiresAt != null && token.kind == 'api')
                      'expires ${formatDate(token.expiresAt!.toLocal())}',
                  ].join(' · '),
                ),
                trailing: TextButton(onPressed: () => revoke(token), child: const Text('Revoke')),
              ),
            if (api)
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Create API token'),
                onTap: create,
              ),
          ],
        );
      },
    );
  }
}

class _NewTokenDialog extends StatefulWidget {
  const _NewTokenDialog();

  @override
  State<_NewTokenDialog> createState() => _NewTokenDialogState();
}

class _NewTokenDialogState extends State<_NewTokenDialog> {
  final _name = TextEditingController();
  final _days = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New API token'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'Home Assistant'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _days,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Expires after (days)',
            hintText: 'Leave empty for never',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () {
          final name = _name.text.trim();
          if (name.isEmpty) return;
          Navigator.pop(context, (name: name, days: int.tryParse(_days.text)));
        },
        child: const Text('Create'),
      ),
    ],
  );
}
