import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../state/auth.dart';
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
    final isToday = date == ref.watch(currentDayProvider);
    final selected = ref.read(selectedDateProvider.notifier);

    // Keep the last summary while another day loads, so the header does not jump.
    final habits = ref.watch(todayProvider).value?.habits.where((h) => h.due).toList() ?? [];
    // A skipped habit is not part of the day, unless it was done anyway.
    habits.removeWhere((h) => h.skipped && !h.done);
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
    final known = {for (final category in view.categories) category.id};
    // Habits without a category (or whose category is gone) come first, unlabelled.
    final loose = due.where((h) => !known.contains(h.categoryId)).toList();

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
          for (final habit in loose) _HabitRow(habit: habit, view: view),
          for (final category in view.categories)
            if (due.any((h) => h.categoryId == category.id)) ...[
              _CategoryHeader(
                category: category,
                habits: due.where((h) => h.categoryId == category.id).toList(),
              ),
              if (!category.collapsed)
                for (final habit in due.where((h) => h.categoryId == category.id))
                  _HabitRow(habit: habit, view: view),
            ],
          if (notDue.isNotEmpty)
            ExpansionTile(
              title: Text('Not scheduled today', style: Theme.of(context).textTheme.bodyMedium),
              tilePadding: const EdgeInsets.symmetric(horizontal: 20),
              children: [for (final habit in notDue) _HabitRow(habit: habit, view: view)],
            ),
        ],
      ),
    );
  }
}

/// A category's name and how much of it is done. Tap to fold or unfold it.
class _CategoryHeader extends ConsumerWidget {
  const _CategoryHeader({required this.category, required this.habits});

  final Category category;
  final List<TodayHabit> habits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final counted = habits.where((h) => h.done || !h.skipped).toList();
    final done = counted.where((h) => h.done).length;
    return InkWell(
      onTap: () => guard(
        context,
        () => ref.read(todayProvider.notifier).setCollapsed(category, !category.collapsed),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                category.name.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Text(
              '$done/${counted.length}',
              style: monoStyle(context, size: 12).copyWith(color: palette.muted),
            ),
            const SizedBox(width: 8),
            Icon(
              category.collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              color: palette.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _HabitRow extends ConsumerWidget {
  const _HabitRow({required this.habit, required this.view});

  final TodayHabit habit;
  final TodayView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final today = ref.read(todayProvider.notifier);
    final isBoolean = habit.kind == HabitKind.boolean;
    final ink = habitInk(context, habit.color);
    // A weekly habit can be checked today without being done for the week.
    final marked = isBoolean ? habit.value > 0 : habit.done;
    final excused = habit.skipped && !marked;
    final detail = [
      if (excused) 'skipped',
      if (habit.progress.isNotEmpty) habit.progress,
      // One period in a row is not worth announcing.
      if (habit.streak > 1) '${streakLength(habit.streak, habit.schedule)} running',
    ].join(' · ');

    void more() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DaySheet(habitId: habit.id),
    );

    /// The quick options: the things done to a habit rather than to its day.
    Future<void> quickMenu(Offset at) async {
      final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
      final action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
        items: [
          PopupMenuItem(
            value: 'skip',
            child: Text(habit.skipped ? 'Do not skip today' : 'Skip today'),
          ),
          const PopupMenuItem(value: 'more', child: Text('Amount, note…')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'history', child: Text('History and stats')),
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          const PopupMenuItem(value: 'archive', child: Text('Archive')),
          PopupMenuItem(
            value: 'delete',
            child: Text('Delete', style: TextStyle(color: palette.danger)),
          ),
        ],
      );
      if (action == null || !context.mounted) return;
      final api = ref.read(apiProvider);
      switch (action) {
        case 'skip':
          await guard(context, () => today.setDay(habit, skipped: !habit.skipped));
        case 'more':
          more();
        case 'history':
          context.push('/habits/${habit.id}/history');
        case 'edit':
          context.push('/habits/${habit.id}');
        case 'archive':
          final ok = await guard(context, () => api.updateHabit(habit.id, {'archived': true}));
          if (ok && context.mounted) {
            invalidateHabits(ref);
            showMessage(context, 'Archived. Restore it from the Habits screen.');
          }
        case 'delete':
          final confirmed = await confirm(
            context,
            title: 'Delete "${habit.name}"?',
            message: 'The habit and all of its history will be deleted. This cannot be undone.',
            action: 'Delete',
          );
          if (!confirmed || !context.mounted) return;
          if (await guard(context, () => api.deleteHabit(habit.id)) && context.mounted) {
            invalidateHabits(ref);
          }
      }
    }

    Offset pressedAt = Offset.zero;
    return InkWell(
      onTap: () => context.push('/habits/${habit.id}/history'),
      // The menu opens where the finger is.
      onTapDown: (details) => pressedAt = details.globalPosition,
      onLongPress: () => quickMenu(pressedAt),
      onSecondaryTapDown: (details) => quickMenu(details.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Stamp(
              marked: marked,
              skipped: excused,
              round: !isBoolean,
              color: ink,
              onTap: isBoolean
                  ? () => guard(context, () => today.setChecked(habit, habit.value == 0))
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Highlighted(
                    habit.name,
                    on: habit.done,
                    style: text.titleMedium!.copyWith(color: excused ? palette.muted : null),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      WeekStrip(habit: habit, view: view, color: ink),
                      if (detail.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(context, size: 12).copyWith(color: palette.muted),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (habit.note.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      habit.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall!.copyWith(
                        color: palette.muted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!isBoolean) ...[
              const SizedBox(width: 4),
              _Stepper(
                value: habit.value,
                color: ink,
                onMinus: habit.value > 0 ? () => guard(context, () => today.add(habit, -1)) : null,
                onPlus: () => guard(context, () => today.add(habit, 1)),
                onMore: more,
              ),
            ],
            IconButton(
              tooltip: 'Skip, note and more',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.more_vert, size: 20, color: palette.muted),
              onPressed: more,
            ),
          ],
        ),
      ),
    );
  }
}

/// `− 5 +` for a counter. Holding `+` offers bigger steps.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.value,
    required this.color,
    required this.onMinus,
    required this.onPlus,
    required this.onMore,
  });

  final int value;
  final Color color;
  final VoidCallback? onMinus;
  final VoidCallback onPlus;
  final VoidCallback onMore;

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
        GestureDetector(
          onLongPress: onMore,
          child: IconButton(
            tooltip: 'Add one (hold for more)',
            style: IconButton.styleFrom(
              backgroundColor: color,
              foregroundColor: palette.paper,
              minimumSize: const Size(40, 40),
            ),
            icon: const Icon(Icons.add, size: 20),
            onPressed: onPlus,
          ),
        ),
      ],
    );
  }
}

/// Everything else that can be done to a habit's day: bigger amounts, an exact
/// value, skipping it, and a note.
class _DaySheet extends ConsumerStatefulWidget {
  const _DaySheet({required this.habitId});

  final String habitId;

  @override
  ConsumerState<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<_DaySheet> {
  final _note = TextEditingController();
  bool _noteLoaded = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _custom(TodayHabit habit, {required bool exact}) async {
    final amount = await showDialog<int>(
      context: context,
      builder: (context) => _AmountDialog(
        title: exact ? 'Set the value' : 'Add an amount',
        label: habit.unit.isEmpty ? 'Amount' : habit.unit,
        initial: exact ? habit.value : null,
      ),
    );
    if (amount == null || !mounted) return;
    final today = ref.read(todayProvider.notifier);
    await guard(
      context,
      () => exact ? today.setDay(habit, value: amount) : today.add(habit, amount),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final view = ref.watch(todayProvider).value;
    final habit = view?.habits.where((h) => h.id == widget.habitId).firstOrNull;
    if (habit == null) return const SizedBox(height: 80);
    if (!_noteLoaded) {
      _note.text = habit.note;
      _noteLoaded = true;
    }
    final today = ref.read(todayProvider.notifier);
    final isCounter = habit.kind == HabitKind.counter;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(habit.name, style: text.titleLarge),
          const SizedBox(height: 2),
          Text(
            [
              formatDate(parseYmd(view!.date)),
              if (habit.progress.isNotEmpty) habit.progress,
            ].join(' · '),
            style: monoStyle(context, size: 12).copyWith(color: palette.muted),
          ),
          if (isCounter) ...[
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final amount in const [5, 10, 25])
                  OutlinedButton(
                    onPressed: () => guard(context, () => today.add(habit, amount)),
                    child: Text('+$amount'),
                  ),
                OutlinedButton(
                  onPressed: () => _custom(habit, exact: false),
                  child: const Text('Other…'),
                ),
                TextButton(
                  onPressed: () => _custom(habit, exact: true),
                  child: const Text('Set exact value'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _note,
            maxLength: 500,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Note for this day',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: 'Save note',
                icon: const Icon(Icons.check),
                onPressed: () async {
                  final ok = await guard(context, () => today.setDay(habit, note: _note.text));
                  if (ok && context.mounted) showMessage(context, 'Note saved');
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Skip this day'),
            subtitle: const Text('Sick, travelling, a day off: it will not break the streak.'),
            value: habit.skipped,
            onChanged: (skipped) => guard(context, () => today.setDay(habit, skipped: skipped)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  context.push('/habits/${habit.id}/history');
                },
                icon: const Icon(Icons.insights_outlined, size: 18),
                label: const Text('History and stats'),
              ),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ],
          ),
        ],
      ),
    );
  }
}

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.title, required this.label, this.initial});

  final String title;
  final String label;
  final int? initial;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _controller = TextEditingController(text: widget.initial?.toString() ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, int.tryParse(_controller.text));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _submit, child: const Text('OK')),
    ],
  );
}
