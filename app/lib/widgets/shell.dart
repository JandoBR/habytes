import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../platform/native.dart';

/// The top-level destinations, as a bottom bar on phones and a rail on wide screens.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static final _destinations = [
    (path: '/', label: 'Today', icon: Icons.today_outlined, selected: Icons.today),
    (path: '/habits', label: 'Habits', icon: Icons.checklist_outlined, selected: Icons.checklist),
    (path: '/settings', label: 'Settings', icon: Icons.settings_outlined, selected: Icons.settings),
    if (Native.available)
      (
        path: '/device',
        label: 'Device',
        icon: Icons.phone_android_outlined,
        selected: Icons.phone_android,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final index = _destinations.indexWhere((d) => d.path == location).clamp(0, 99);
    void go(int index) => context.go(_destinations[index].path);

    if (MediaQuery.sizeOf(context).width >= 720) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: go,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline)),
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: go,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selected),
                label: d.label,
              ),
          ],
        ),
      ),
    );
  }
}
