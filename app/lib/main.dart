import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'platform/native.dart';
import 'router.dart';
import 'screens/server.dart';
import 'screens/sign_in.dart';
import 'state/auth.dart';
import 'widgets/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  // Keep the address bar in step with pushed screens, so reloads and links work.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  runApp(const ProviderScope(child: HabytesApp()));
}

ThemeData _theme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D6B), brightness: brightness),
  inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
);

class HabytesApp extends ConsumerStatefulWidget {
  const HabytesApp({super.key});

  @override
  ConsumerState<HabytesApp> createState() => _HabytesAppState();
}

class _HabytesAppState extends ConsumerState<HabytesApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.refreshWidgets();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Native.refreshWidgets();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final signedIn = auth.value is SignedIn;

    if (signedIn) {
      return MaterialApp.router(
        title: 'HaBytes',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        routerConfig: ref.watch(routerProvider),
      );
    }
    return MaterialApp(
      title: 'HaBytes',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: switch (auth) {
        AsyncData(value: NeedsServer()) => const ServerScreen(),
        // On the web the browser is already on its way to the login page.
        AsyncData(value: SignedOut()) =>
          kIsWeb ? const Scaffold(body: Center(child: Text('Redirecting to sign-in…'))) : const SignInScreen(),
        AsyncError(:final error) => Scaffold(
          body: ErrorView(error: error, onRetry: () => ref.invalidate(authProvider)),
        ),
        _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
      },
    );
  }
}
