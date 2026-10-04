import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/auth.dart';

/// Android: starts the login in a browser tab.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signIn();
    } on PlatformException catch (error) {
      // Closing the browser tab is not worth an error message.
      if (mounted && error.code != 'CANCELED') setState(() => _error = error.message);
    } on Exception catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value;
    final server = auth is SignedOut ? auth.serverUrl : '';
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sign in', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(server),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 16),
              ],
              FilledButton(
                onPressed: _busy ? null : _signIn,
                child: Text(_busy ? 'Waiting for sign-in…' : 'Sign in'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : ref.read(authProvider.notifier).changeServer,
                child: const Text('Use a different server'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
