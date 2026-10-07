import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// `Every day`, `Mon, Wed, Fri`, `3 days a week`, `2 days every 3 months`, ...
String describeSchedule(Habit habit) {
  final counter = habit.kind == HabitKind.counter;
  final amount = habit.unit.isEmpty ? '${habit.goal}' : '${habit.goal} ${habit.unit}';
  return switch (habit.schedule) {
    Schedule.daily => counter ? '$amount every day' : 'Every day',
    Schedule.weekdays =>
      '${counter ? '$amount on ' : ''}${habit.weekdays!.map((d) => weekdayShort[d - 1]).join(', ')}',
    Schedule.interval when habit.every == 1 => counter ? '$amount every day' : 'Every day',
    Schedule.interval =>
      counter ? '$amount every ${habit.every} days' : 'Every ${habit.every} days',
    Schedule.weekly || Schedule.monthly || Schedule.yearly =>
      '${counter ? amount : '${habit.goal} day${habit.goal == 1 ? '' : 's'}'} '
          '${periodRate(habit.schedule, habit.every)}',
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
    final categoryNames = {
      for (final category in ref.watch(categoriesProvider).value ?? const <Category>[])
        category.id: category.name,
    };
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
            leading: Container(width: 6, height: 32, color: habitInk(context, habit.color)),
            minLeadingWidth: 6,
            subtitle: Text([describeSchedule(habit), ?categoryNames[habit.categoryId]].join(' · ')),
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
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Categories'),
            const _Categories(),
            if (archived.isNotEmpty) ...[
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
          ],
        ),
      ),
    );
  }
}

/// Add, rename, reorder and delete categories. Habits are put into one in
/// their editor; folding is done on Today.
class _Categories extends ConsumerWidget {
  const _Categories();

  Future<String?> _askName(BuildContext context, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(initial.isEmpty ? 'New category' : 'Rename category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'Health'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiProvider);

    Future<void> run(Future<void> Function() action) async {
      if (await guard(context, action)) invalidateHabits(ref);
    }

    return AsyncView(
      value: ref.watch(categoriesProvider),
      onRetry: () => ref.invalidate(categoriesProvider),
      builder: (categories) {
        void move(int from, int to) {
          final ids = [for (final category in categories) category.id];
          ids.insert(to, ids.removeAt(from));
          run(() => api.reorderCategories(ids));
        }

        return Column(
          children: [
            for (final (index, category) in categories.indexed)
              ListTile(
                title: Text(category.name),
                contentPadding: const EdgeInsets.only(left: 16, right: 4),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Move up',
                      icon: const Icon(Icons.arrow_upward, size: 20),
                      onPressed: index == 0 ? null : () => move(index, index - 1),
                    ),
                    IconButton(
                      tooltip: 'Move down',
                      icon: const Icon(Icons.arrow_downward, size: 20),
                      onPressed: index == categories.length - 1
                          ? null
                          : () => move(index, index + 1),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'rename') {
                          final name = await _askName(context, initial: category.name);
                          if (name == null || name.trim().isEmpty) return;
                          await run(() => api.updateCategory(category.id, name: name.trim()));
                        } else {
                          final ok = await confirm(
                            context,
                            title: 'Delete "${category.name}"?',
                            message: 'Its habits are kept, without a category.',
                            action: 'Delete',
                          );
                          if (ok) await run(() => api.deleteCategory(category.id));
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add category'),
              onTap: () async {
                final name = await _askName(context);
                if (name == null || name.trim().isEmpty) return;
                await run(() => api.createCategory(name.trim()));
              },
            ),
          ],
        );
      },
    );
  }
}
