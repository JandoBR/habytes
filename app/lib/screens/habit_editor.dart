import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../widgets/common.dart';

/// Creates a habit, or edits the one with [habitId].
class HabitEditorScreen extends ConsumerStatefulWidget {
  const HabitEditorScreen({super.key, this.habitId});

  final String? habitId;

  @override
  ConsumerState<HabitEditorScreen> createState() => _HabitEditorScreenState();
}

class _HabitEditorScreenState extends ConsumerState<HabitEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _goal = TextEditingController(text: '1');
  HabitKind _kind = HabitKind.boolean;
  Schedule _schedule = Schedule.daily;
  Set<int> _weekdays = {1, 2, 3, 4, 5};

  Habit? _habit;
  Object? _loadError;
  bool _loading = false;
  bool _busy = false;

  bool get _isNew => widget.habitId == null;

  @override
  void initState() {
    super.initState();
    if (!_isNew) _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _goal.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final habits = await ref.read(habitsProvider.future);
      final habit = habits.where((h) => h.id == widget.habitId).firstOrNull;
      if (!mounted) return;
      if (habit == null) {
        setState(() => _loadError = 'This habit no longer exists.');
        return;
      }
      setState(() {
        _habit = habit;
        _name.text = habit.name;
        _description.text = habit.description;
        _goal.text = '${habit.goal}';
        _kind = habit.kind;
        _schedule = habit.schedule;
        _weekdays = habit.weekdays?.toSet() ?? _weekdays;
      });
    } on Exception catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// A boolean habit only has a goal when it is weekly.
  bool get _hasGoal => _kind == HabitKind.counter || _schedule == Schedule.weekly;

  String get _goalLabel => switch ((_kind, _schedule)) {
    (HabitKind.boolean, _) => 'Days per week',
    (HabitKind.counter, Schedule.weekly) => 'Total per week',
    (HabitKind.counter, _) => 'Per day',
  };

  String? _validateGoal(String? text) {
    final goal = int.tryParse(text ?? '');
    if (goal == null || goal < 1) return 'Enter a number of at least 1';
    if (_kind == HabitKind.boolean && goal > 7) return 'A week has 7 days';
    return null;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    final ok = await guard(context, action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      invalidateHabits(ref);
      context.pop();
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_schedule == Schedule.weekdays && _weekdays.isEmpty) {
      showMessage(context, 'Pick at least one day.');
      return;
    }
    final api = ref.read(apiProvider);
    final goal = _hasGoal ? int.parse(_goal.text) : 1;
    final weekdays = _schedule == Schedule.weekdays ? (_weekdays.toList()..sort()) : null;

    await _run(() async {
      if (_isNew) {
        await api.createHabit(
          name: _name.text.trim(),
          description: _description.text.trim(),
          kind: _kind,
          schedule: _schedule,
          weekdays: weekdays,
          goal: goal,
        );
      } else {
        await api.updateHabit(widget.habitId!, {
          'name': _name.text.trim(),
          'description': _description.text.trim(),
          'schedule': _schedule.name,
          'weekdays': weekdays,
          'goal': goal,
        });
      }
    });
  }

  Future<void> _archive() =>
      _run(() => ref.read(apiProvider).updateHabit(widget.habitId!, {'archived': true}));

  Future<void> _delete() async {
    final confirmed = await confirm(
      context,
      title: 'Delete habit?',
      message: '"${_habit?.name}" and all of its history will be deleted. This cannot be undone.',
      action: 'Delete',
    );
    if (confirmed) await _run(() => ref.read(apiProvider).deleteHabit(widget.habitId!));
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loadError != null) {
      body = ErrorView(error: _loadError!, onRetry: _load);
    } else if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _buildForm(context);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New habit' : 'Edit habit'),
        actions: [
          if (_habit != null) ...[
            if (!_habit!.archived)
              IconButton(
                tooltip: 'Archive',
                icon: const Icon(Icons.archive_outlined),
                onPressed: _busy ? null : _archive,
              ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _delete,
            ),
          ],
        ],
      ),
      body: body,
    );
  }

  Widget _buildForm(BuildContext context) => Centered(
    maxWidth: 560,
    child: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _name,
            autofocus: _isNew,
            maxLength: 100,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name'),
            validator: (text) => (text ?? '').trim().isEmpty ? 'Give the habit a name' : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _description,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
          const SizedBox(height: 24),
          Text('Type', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<HabitKind>(
            segments: const [
              ButtonSegment(
                value: HabitKind.boolean,
                label: Text('Yes / no'),
                icon: Icon(Icons.check_box_outlined),
              ),
              ButtonSegment(
                value: HabitKind.counter,
                label: Text('Counter'),
                icon: Icon(Icons.exposure_plus_1),
              ),
            ],
            selected: {_kind},
            // The kind cannot change once the habit exists.
            onSelectionChanged: _isNew ? (kinds) => setState(() => _kind = kinds.first) : null,
          ),
          const SizedBox(height: 24),
          Text('Schedule', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<Schedule>(
            segments: const [
              ButtonSegment(value: Schedule.daily, label: Text('Every day')),
              ButtonSegment(value: Schedule.weekdays, label: Text('Pick days')),
              ButtonSegment(value: Schedule.weekly, label: Text('Weekly target')),
            ],
            selected: {_schedule},
            onSelectionChanged: (schedules) => setState(() => _schedule = schedules.first),
          ),
          if (_schedule == Schedule.weekdays) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var day = 1; day <= 7; day++)
                  FilterChip(
                    label: Text(weekdayShort[day - 1]),
                    selected: _weekdays.contains(day),
                    onSelected: (selected) => setState(() {
                      selected ? _weekdays.add(day) : _weekdays.remove(day);
                    }),
                  ),
              ],
            ),
          ],
          if (_hasGoal) ...[
            const SizedBox(height: 24),
            TextFormField(
              controller: _goal,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: _goalLabel),
              validator: _validateGoal,
            ),
          ],
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_isNew ? 'Create habit' : 'Save'),
          ),
        ],
      ),
    ),
  );
}
