import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../widgets/common.dart';

/// `Every day`, `Mon, Wed, Fri`, `3 days a week`, ...
String describeSchedule(Habit habit) {
  final counter = habit.kind == HabitKind.counter;
  return switch (habit.schedule) {
    Schedule.daily => counter ? '${habit.goal} every day' : 'Every day',
    Schedule.weekdays =>
      '${counter ? '${habit.goal} on ' : ''}${habit.weekdays!.map((d) => weekdayShort[d - 1]).join(', ')}',
    Schedule.weekly => counter ? '${habit.goal} a week' : '${habit.goal} days a week',
  };
}

/// Reorder active habits and restore archived ones.
class ManageScreen extends ConsumerWidget {
  const ManageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Habits')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => context.push('/habits/new'),
      icon: const Icon(Icons.add),
      label: const Text('Habit'),
    ),
    body: AsyncView(
      value: ref.watch(habitsProvider),
      onRetry: () => ref.invalidate(habitsProvider),
      builder: (habits) => _Lists(habits: habits),
    ),
  );
}

class _Lists extends ConsumerStatefulWidget {
  const _Lists({required this.habits});

  final List<Habit> habits;

  @override
  ConsumerState<_Lists> createState() => _ListsState();
}

class _ListsState extends ConsumerState<_Lists> {
  late List<Habit> _active;

  @override
  void initState() {
    super.initState();
    _active = widget.habits.where((h) => !h.archived).toList();
  }

  @override
  void didUpdateWidget(_Lists old) {
    super.didUpdateWidget(old);
    if (old.habits != widget.habits) {
      _active = widget.habits.where((h) => !h.archived).toList();
    }
  }

  Future<void> _reorder(int from, int to) async {
    setState(() => _active.insert(to, _active.removeAt(from)));
    final ok = await guard(
      context,
      () => ref.read(apiProvider).reorderHabits([for (final habit in _active) habit.id]),
    );
    if (mounted) ok ? invalidateHabits(ref) : ref.invalidate(habitsProvider);
  }

  Future<void> _restore(Habit habit) async {
    final ok = await guard(
      context,
      () => ref.read(apiProvider).updateHabit(habit.id, {'archived': false}),
    );
    if (ok && mounted) invalidateHabits(ref);
  }

  @override
  Widget build(BuildContext context) {
    final archived = widget.habits.where((h) => h.archived).toList();
    if (widget.habits.isEmpty) {
      return const Center(child: Text('No habits yet.'));
    }
    return Centered(
      child: ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: _active.length,
        onReorderItem: _reorder,
        header: _active.isEmpty
            ? null
            : const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Drag to change the order habits appear in.'),
              ),
        itemBuilder: (context, index) {
          final habit = _active[index];
          return ListTile(
            key: ValueKey(habit.id),
            title: Text(habit.name),
            subtitle: Text(describeSchedule(habit)),
            // Leave room for the drag handle shown on desktop and web.
            contentPadding: const EdgeInsets.only(left: 16, right: 48),
            trailing: IconButton(
              tooltip: 'History',
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: () => context.push('/habits/${habit.id}/history'),
            ),
            onTap: () => context.push('/habits/${habit.id}'),
          );
        },
        footer: archived.isEmpty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionTitle('Archived'),
                  for (final habit in archived)
                    ListTile(
                      title: Text(habit.name),
                      subtitle: Text(describeSchedule(habit)),
                      trailing: TextButton(
                        onPressed: () => _restore(habit),
                        child: const Text('Restore'),
                      ),
                      onTap: () => context.push('/habits/${habit.id}'),
                    ),
                ],
              ),
      ),
    );
  }
}
