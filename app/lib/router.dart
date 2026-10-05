import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/device.dart';
import 'screens/habit_editor.dart';
import 'screens/history.dart';
import 'screens/manage.dart';
import 'screens/settings.dart';
import 'screens/today.dart';
import 'widgets/shell.dart';

/// Where the browser was when the app started. The sign-in gate shown first
/// resets the address bar to `/`, so the router has to be told where to open.
String startLocation = '/';

/// The signed-in part of the app.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: startLocation,
    // An address that leads nowhere is not worth an error page.
    onException: (_, _, router) => router.go('/'),
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (_, _) => const NoTransitionPage(child: TodayScreen()),
          ),
          GoRoute(
            path: '/habits',
            pageBuilder: (_, _) => const NoTransitionPage(child: ManageScreen()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (_, _) => const NoTransitionPage(child: SettingsScreen()),
          ),
          GoRoute(
            path: '/device',
            pageBuilder: (_, _) => const NoTransitionPage(child: DeviceScreen()),
          ),
        ],
      ),
      GoRoute(path: '/habits/new', builder: (_, _) => const HabitEditorScreen()),
      GoRoute(
        path: '/habits/:id',
        builder: (_, state) => HabitEditorScreen(habitId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/habits/:id/history',
        builder: (_, state) => HistoryScreen(habitId: state.pathParameters['id']!),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
