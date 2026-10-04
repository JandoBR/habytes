import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../state/data.dart';
import '../widgets/common.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = ref.watch(selectedDateProvider);
    final isToday = date == localToday();
    final selected = ref.read(selectedDateProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(isToday ? 'Today' : formatDate(date)),
        actions: [
          if (!isToday) TextButton(onPressed: selected.reset, child: const Text('Today')),
          IconButton(
            tooltip: 'Previous day',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => selected.shift(-1),
          ),
          IconButton(
            tooltip: 'Next day',
            icon: const Icon(Icons.chevron_right),
            onPressed: isToday ? null : () => selected.shift(1),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/habits/new'),
        icon: const Icon(Icons.add),
        label: const Text('Habit'),
      ),
      body: AsyncView(
        value: ref.watch(todayProvider),
        onRetry: () => ref.invalidate(todayProvider),
        builder: (view) => _HabitList(view: view),
      ),
    );
  }
}

class _HabitList extends ConsumerWidget {
  const _HabitList({required this.view});

  final TodayView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (view.habits.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No habits yet. Add your first one.', textAlign: TextAlign.center),
        ),
      );
    }
    final due = view.habits.where((h) => h.due).toList();
    final notDue = view.habits.where((h) => !h.due).toList();

    return RefreshIndicator(
      onRefresh: () => ref.refresh(todayProvider.future),
      child: Centered(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (due.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Nothing is due on this day.', textAlign: TextAlign.center),
              ),
            for (final habit in due) _HabitTile(habit: habit),
            if (notDue.isNotEmpty)
              ExpansionTile(
                title: const Text('Not scheduled today'),
                shape: const Border(),
                children: [for (final habit in notDue) _HabitTile(habit: habit)],
              ),
          ],
        ),
      ),
    );
  }
}

class _HabitTile extends ConsumerWidget {
  const _HabitTile({required this.habit});

  final TodayHabit habit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final today = ref.read(todayProvider.notifier);
    final isBoolean = habit.kind == HabitKind.boolean;

    return ListTile(
      leading: isBoolean
          ? Checkbox(
              value: habit.value > 0,
              onChanged: (checked) =>
                  guard(context, () => today.setChecked(habit, checked ?? false)),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                habit.done ? Icons.check_circle : Icons.radio_button_unchecked,
                color: habit.done ? colors.primary : colors.outline,
              ),
            ),
      title: Text(
        habit.name,
        style: habit.done ? TextStyle(color: colors.onSurfaceVariant) : null,
      ),
      subtitle: habit.progress.isEmpty
          ? null
          : Text(
              habit.done ? '${habit.progress} · done' : habit.progress,
              style: habit.done ? TextStyle(color: colors.primary) : null,
            ),
      trailing: isBoolean
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Subtract one',
                  icon: const Icon(Icons.remove),
                  onPressed: habit.value > 0
                      ? () => guard(context, () => today.add(habit, -1))
                      : null,
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 28),
                  child: Text(
                    '${habit.value}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Add one',
                  icon: const Icon(Icons.add),
                  onPressed: () => guard(context, () => today.add(habit, 1)),
                ),
              ],
            ),
      onTap: () => context.push('/habits/${habit.id}/history'),
    );
  }
}
