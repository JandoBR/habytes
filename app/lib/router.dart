import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/device.dart';
import 'screens/habit_editor.dart';
import 'screens/history.dart';
import 'screens/manage.dart';
import 'screens/settings.dart';
import 'screens/today.dart';
import 'widgets/shell.dart';

/// The signed-in part of the app.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', pageBuilder: (_, _) => const NoTransitionPage(child: TodayScreen())),
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
