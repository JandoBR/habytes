import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../state/data.dart';
import '../theme.dart';
import '../widgets/common.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => context.push('/habits/new'),
      icon: const Icon(Icons.add),
      label: const Text('Habit'),
    ),
    body: SafeArea(
      bottom: false,
      child: Centered(
        child: Column(
          children: [
            const _Header(),
            Expanded(
              child: AsyncView(
                value: ref.watch(todayProvider),
                onRetry: () => ref.invalidate(todayProvider),
                builder: (view) => _HabitList(view: view),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The day being shown, how much of it is done, and the way to other days.
class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final date = ref.watch(selectedDateProvider);
    final isToday = date == localToday();
    final selected = ref.read(selectedDateProvider.notifier);

    // Keep the last summary while another day loads, so the header does not jump.
    final habits = ref.watch(todayProvider).value?.habits.where((h) => h.due).toList() ?? [];
    final done = habits.where((h) => h.done).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (isToday ? 'Today · ' : '') + weekdayNames[date.weekday - 1],
                  style: text.titleSmall!.copyWith(color: palette.muted),
                ),
              ),
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
          Text('${date.day} ${monthNames[date.month - 1]}', style: text.displaySmall),
          if (habits.isNotEmpty) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Meter(value: done, goal: habits.length, height: 8),
                  ),
                  const SizedBox(width: 12),
                  Text('$done/${habits.length} done', style: monoStyle(context, size: 13)),
                ],
              ),
            ),
          ],
        ],
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
      child: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          const Divider(),
          if (due.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Nothing is due on this day.', textAlign: TextAlign.center),
            ),
          for (final habit in due) _HabitRow(habit: habit),
          if (notDue.isNotEmpty)
            ExpansionTile(
              title: Text('Not scheduled today', style: Theme.of(context).textTheme.bodyMedium),
              tilePadding: const EdgeInsets.symmetric(horizontal: 20),
              children: [for (final habit in notDue) _HabitRow(habit: habit)],
            ),
        ],
      ),
    );
  }
}

class _HabitRow extends ConsumerWidget {
  const _HabitRow({required this.habit});

  final TodayHabit habit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final today = ref.read(todayProvider.notifier);
    final isBoolean = habit.kind == HabitKind.boolean;
    // A weekly habit can be checked today without being done for the week.
    final marked = isBoolean ? habit.value > 0 : habit.done;

    return InkWell(
      onTap: () => context.push('/habits/${habit.id}/history'),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Stamp(
              marked: marked,
              round: !isBoolean,
              onTap: isBoolean
                  ? () => guard(context, () => today.setChecked(habit, habit.value == 0))
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Highlighted(habit.name, on: habit.done, style: text.titleMedium, maxLines: 2),
                  if (habit.progress.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        SizedBox(
                          width: 84,
                          child: Meter(value: habit.periodValue, goal: habit.goal),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            habit.progress,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(context, size: 12).copyWith(color: palette.muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (!isBoolean) ...[
              const SizedBox(width: 8),
              _Stepper(
                value: habit.value,
                onMinus: habit.value > 0 ? () => guard(context, () => today.add(habit, -1)) : null,
                onPlus: () => guard(context, () => today.add(habit, 1)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `− 5 +` for a counter.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onMinus, required this.onPlus});

  final int value;
  final VoidCallback? onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Subtract one',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove, size: 20),
          onPressed: onMinus,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 26),
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: monoStyle(context, size: 17, medium: true),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Add one',
          style: IconButton.styleFrom(
            backgroundColor: palette.ink,
            foregroundColor: palette.paper,
            minimumSize: const Size(40, 40),
          ),
          icon: const Icon(Icons.add, size: 20),
          onPressed: onPlus,
        ),
      ],
    );
  }
}
