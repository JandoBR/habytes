import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../platform/native.dart';
import '../platform/nfc.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// How a habit comes round: every day, on picked weekdays, some days after it
/// was last done, or as a target over a week, a month, a year or several of them.
enum _Rhythm { daily, weekdays, interval, target }

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

  /// Whether a target's period is several weeks, months or years: [_every] of them.
  bool _custom = false;
  final _every = TextEditingController(text: '2');

  /// The days an interval habit rests after it is done.
  final _interval = TextEditingController(text: '3');
  Set<int> _weekdays = {1, 2, 3, 4, 5};
  final _unit = TextEditingController();
  String _color = 'ink';
  String? _categoryId;
  List<Reminder> _reminders = [];

  /// Bumped to put the category field back on the habit's own category.
  int _categoryResets = 0;
  String? _webhookUrl;

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
    _every.dispose();
    _interval.dispose();
    _unit.dispose();
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
        if (habit.schedule == Schedule.interval) {
          _interval.text = '${habit.every}';
        } else if (habit.every > 1) {
          _custom = true;
          _every.text = '${habit.every}';
        }
        _weekdays = habit.weekdays?.toSet() ?? _weekdays;
        _unit.text = habit.unit;
        _color = habit.color;
        _categoryId = habit.categoryId;
        _webhookUrl = habit.webhookUrl;
        _reminders = [...habit.reminders];
      });
    } on Exception catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  _Rhythm get _rhythm => switch (_schedule) {
    Schedule.daily => _Rhythm.daily,
    Schedule.weekdays => _Rhythm.weekdays,
    Schedule.interval => _Rhythm.interval,
    Schedule.weekly || Schedule.monthly || Schedule.yearly => _Rhythm.target,
  };

  void _setRhythm(_Rhythm rhythm) {
    if (rhythm == _rhythm) return;
    setState(() {
      _schedule = switch (rhythm) {
        _Rhythm.daily => Schedule.daily,
        _Rhythm.weekdays => Schedule.weekdays,
        _Rhythm.interval => Schedule.interval,
        _Rhythm.target => Schedule.weekly,
      };
      _custom = false;
    });
  }

  /// How many weeks, months or years the target's period spans, or the days
  /// of an interval.
  int get _everyCount {
    if (_schedule == Schedule.interval) return (int.tryParse(_interval.text) ?? 1).clamp(1, 365);
    return _schedule.isTarget && _custom ? (int.tryParse(_every.text) ?? 1).clamp(1, 52) : 1;
  }

  /// A boolean habit only has a goal when it is a target.
  bool get _hasGoal => _kind == HabitKind.counter || _schedule.isTarget;

  String get _goalLabel {
    if (_schedule == Schedule.interval) return 'Each time';
    if (!_schedule.isTarget) return 'Per day';
    final every = _everyCount;
    final over = every == 1 ? 'per ${_schedule.unit}' : 'every $every ${_schedule.unit}s';
    return '${_kind == HabitKind.boolean ? 'Days' : 'Total'} $over';
  }

  /// The most days a yes/no target can ask for, as the server counts them.
  int get _maxDays => switch (_schedule) {
    Schedule.weekly => 7 * _everyCount,
    Schedule.monthly => 365 * _everyCount ~/ 12,
    Schedule.yearly => 365 * _everyCount,
    Schedule.daily || Schedule.weekdays || Schedule.interval => 1,
  };

  String? _validateGoal(String? text) {
    final goal = int.tryParse(text ?? '');
    if (goal == null || goal < 1) return 'Enter a number of at least 1';
    if (_kind == HabitKind.boolean && goal > _maxDays) {
      final every = _everyCount;
      final period = every == 1 ? 'A ${_schedule.unit}' : '$every ${_schedule.unit}s';
      return '$period ${every == 1 ? 'has' : 'have'} $_maxDays days';
    }
    return null;
  }

  String? _validateInterval(String? text) {
    final days = int.tryParse(text ?? '');
    return days == null || days < 1 || days > 365 ? 'From 1 to 365' : null;
  }

  String? _validateEvery(String? text) {
    final every = int.tryParse(text ?? '');
    return every == null || every < 1 || every > 52 ? 'From 1 to 52' : null;
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
    final unit = _kind == HabitKind.counter ? _unit.text.trim() : '';
    final reminders = [for (final reminder in _reminders) reminder.fitTo(_dueDays)];

    await _run(() async {
      if (_isNew) {
        await api.createHabit(
          name: _name.text.trim(),
          description: _description.text.trim(),
          kind: _kind,
          schedule: _schedule,
          every: _everyCount,
          weekdays: weekdays,
          goal: goal,
          unit: unit,
          color: _color,
          categoryId: _categoryId,
          reminders: reminders,
        );
      } else {
        await api.updateHabit(widget.habitId!, {
          'name': _name.text.trim(),
          'description': _description.text.trim(),
          'schedule': _schedule.name,
          'every': _everyCount,
          'weekdays': weekdays,
          'goal': goal,
          'unit': unit,
          'color': _color,
          'category_id': _categoryId,
          'reminders': [for (final reminder in reminders) reminder.toJson()],
        });
      }
    });
  }

  Future<void> _newCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New category'),
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
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await guard(context, () async {
      final category = await ref.read(apiProvider).createCategory(name.trim());
      ref.invalidate(categoriesProvider);
      if (mounted) setState(() => _categoryId = category.id);
    });
  }

  /// The days the habit is due, when it is not due every day: it is only
  /// reminded on those.
  Set<int>? get _dueDays => _schedule == Schedule.weekdays ? _weekdays : null;

  /// Adds a reminder, or changes the one at [index].
  Future<void> _editReminder([int? index]) async {
    final due = _dueDays;
    final reminder = await showDialog<Reminder>(
      context: context,
      builder: (context) => _ReminderDialog(
        initial: index == null ? null : _reminders[index].fitTo(due),
        dueDays: due == null ? null : {...due},
      ),
    );
    if (reminder == null || !mounted) return;
    setState(() {
      if (index == null) {
        _reminders = [..._reminders, reminder];
      } else {
        _reminders = [..._reminders]..[index] = reminder;
      }
      _reminders.sort((a, b) => a.time.compareTo(b.time));
    });
    await Native.requestNotifications();
  }

  /// Creates the habit's webhook, or replaces it with a new address.
  Future<void> _createWebhook({required bool rotate}) async {
    if (rotate) {
      final ok = await confirm(
        context,
        title: 'Replace the webhook?',
        message: 'The current address stops working, and whatever uses it needs the new one.',
        action: 'Replace',
      );
      if (!ok || !mounted) return;
    }
    await guard(context, () async {
      final url = await ref.read(apiProvider).createWebhook(widget.habitId!);
      ref.invalidate(habitsProvider);
      if (mounted) setState(() => _webhookUrl = url);
    });
  }

  Future<void> _removeWebhook() async {
    final ok = await confirm(
      context,
      title: 'Remove the webhook?',
      message: 'Requests to its address will no longer log this habit.',
      action: 'Remove',
    );
    if (!ok || !mounted) return;
    await guard(context, () async {
      await ref.read(apiProvider).deleteWebhook(widget.habitId!);
      ref.invalidate(habitsProvider);
      if (mounted) setState(() => _webhookUrl = null);
    });
  }

  Future<void> _copyWebhook() async {
    await Clipboard.setData(ClipboardData(text: _webhookUrl!));
    if (mounted) showMessage(context, 'Webhook address copied');
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

  Future<void> _writeTag() async {
    if (await writeHabitTag(context, _habit!) && mounted) {
      showMessage(context, 'Tag written. Tap it with the phone to log this habit.');
    }
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
            showSelectedIcon: false,
            selected: {_kind},
            // The kind cannot change once the habit exists.
            onSelectionChanged: _isNew ? (kinds) => setState(() => _kind = kinds.first) : null,
          ),
          const SizedBox(height: 24),
          Text('Schedule', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (rhythm, label) in const [
                (_Rhythm.daily, 'Every day'),
                (_Rhythm.weekdays, 'Pick days'),
                (_Rhythm.interval, 'Every few days'),
                (_Rhythm.target, 'Target'),
              ])
                ChoiceChip(
                  label: Text(label),
                  showCheckmark: false,
                  selected: _rhythm == rhythm,
                  onSelected: (_) => _setRhythm(rhythm),
                ),
            ],
          ),
          if (_schedule == Schedule.interval) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _interval,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Days between',
                helperText: 'Due again this many days after it was last done.',
              ),
              validator: _validateInterval,
            ),
          ],
          if (_schedule.isTarget) ..._targetPeriod(context),
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
          if (_kind == HabitKind.counter) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _unit,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: 'Unit (optional)',
                hintText: 'pages, ml, minutes',
                counterText: '',
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('Colour', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            children: [
              for (final color in habitColors)
                Tooltip(
                  message: color,
                  child: InkResponse(
                    onTap: () => setState(() => _color = color),
                    radius: 24,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: habitInk(context, color),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: _color == color
                          ? Icon(Icons.check, size: 20, color: AppPalette.of(context).paper)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          _categoryField(context),
          const SizedBox(height: 16),
          Text('Reminders', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            Native.available
                ? 'A notification at that time if the habit is not done yet.'
                : 'Shown by the Android app, at that time, if the habit is not done yet.',
            style: Theme.of(context).textTheme.bodySmall!
                .copyWith(color: AppPalette.of(context).muted),
          ),
          const SizedBox(height: 4),
          for (final (index, reminder) in _reminders.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.notifications_none),
              title: Text(
                '${reminder.time} · ${reminder.daysText(_dueDays)}',
                style: monoStyle(context, size: 14),
              ),
              trailing: IconButton(
                tooltip: 'Remove reminder',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => setState(() => _reminders = [..._reminders]..removeAt(index)),
              ),
              onTap: () => _editReminder(index),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _reminders.length >= 12 ? null : _editReminder,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add reminder'),
            ),
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_isNew ? 'Create habit' : 'Save'),
          ),
          if (_habit != null && Native.available) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _writeTag,
              icon: const Icon(Icons.nfc),
              label: const Text('Write NFC tag'),
            ),
          ],
          if (_habit != null) ..._webhook(context),
        ],
      ),
    ),
  );

  /// What a target is set over: a week, a month, a year, or a number of them.
  List<Widget> _targetPeriod(BuildContext context) {
    const units = [Schedule.weekly, Schedule.monthly, Schedule.yearly];
    return [
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final unit in units)
            ChoiceChip(
              label: Text('Per ${unit.unit}'),
              showCheckmark: false,
              selected: !_custom && _schedule == unit,
              onSelected: (_) => setState(() {
                _schedule = unit;
                _custom = false;
              }),
            ),
          ChoiceChip(
            label: const Text('Custom'),
            showCheckmark: false,
            selected: _custom,
            onSelected: (_) => setState(() => _custom = true),
          ),
        ],
      ),
      if (_custom) ...[
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: TextFormField(
                controller: _every,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Every'),
                validator: _validateEvery,
                // The goal's label and limit follow it.
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<Schedule>(
                key: ValueKey(_schedule),
                initialValue: _schedule,
                decoration: const InputDecoration(labelText: 'Of'),
                items: [
                  for (final unit in units)
                    DropdownMenuItem(value: unit, child: Text('${unit.unit}s')),
                ],
                onChanged: (unit) => setState(() => _schedule = unit ?? _schedule),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          switch (_schedule) {
            Schedule.weekly => 'Counted in whole weeks.',
            Schedule.monthly => 'Counted in calendar months from January, so 3 is a quarter.',
            _ => 'Counted in calendar years.',
          },
          style: Theme.of(context).textTheme.bodySmall!
              .copyWith(color: AppPalette.of(context).muted),
        ),
      ],
    ];
  }

  /// The habit's webhook: an address that logs it when something sends a POST there.
  List<Widget> _webhook(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = AppPalette.of(context);
    final kind = _kind == HabitKind.counter ? 'adds one (or ?delta=N)' : 'checks it for today';
    return [
      const SizedBox(height: 32),
      Text('Webhook', style: text.labelLarge),
      const SizedBox(height: 4),
      Text(
        'For automations: a POST request to this address $kind. '
        'Anyone who has the address can log the habit, and nothing else.',
        style: text.bodySmall!.copyWith(color: palette.muted),
      ),
      const SizedBox(height: 12),
      if (_webhookUrl == null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _createWebhook(rotate: false),
            icon: const Icon(Icons.link),
            label: const Text('Create webhook'),
          ),
        )
      else ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(_webhookUrl!, style: monoStyle(context, size: 12)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _copyWebhook,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
            TextButton(onPressed: () => _createWebhook(rotate: true), child: const Text('Replace')),
            TextButton(onPressed: _removeWebhook, child: const Text('Remove')),
          ],
        ),
      ],
    ];
  }

  /// The habit's category: none, an existing one, or a new one made on the spot.
  Widget _categoryField(BuildContext context) {
    const create = '\u0000new';
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    // A category that is gone must not leave the dropdown without its value.
    final current = categories.any((c) => c.id == _categoryId) ? _categoryId : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('$current-${categories.length}-$_categoryResets'),
      initialValue: current,
      decoration: const InputDecoration(labelText: 'Category'),
      items: [
        const DropdownMenuItem(value: null, child: Text('None')),
        for (final category in categories)
          DropdownMenuItem(value: category.id, child: Text(category.name)),
        const DropdownMenuItem(value: create, child: Text('New category…')),
      ],
      onChanged: (value) {
        if (value == create) {
          // Not a category itself: if none gets made, the field shows the old one again.
          _newCategory().whenComplete(() {
            if (mounted) setState(() => _categoryResets++);
          });
        } else {
          setState(() => _categoryId = value);
        }
      },
    );
  }
}

/// A reminder's time and the days it goes off on.
class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog({required this.initial, required this.dueDays});

  final Reminder? initial;

  /// The days the habit is due, when it is not due every day.
  final Set<int>? dueDays;

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  late TimeOfDay _time;

  /// Whether it goes off on [_days] only, rather than whenever the habit is due.
  late bool _someDays;
  late Set<int> _days;

  /// The days there are to choose from: the ones the habit is due on.
  late final List<int> _offered = (widget.dueDays ?? {1, 2, 3, 4, 5, 6, 7}).toList()..sort();

  @override
  void initState() {
    super.initState();
    final parts = widget.initial?.time.split(':');
    _time = parts == null
        ? const TimeOfDay(hour: 20, minute: 0)
        : TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    final days = widget.initial?.days;
    _someDays = days != null;
    _days = days?.toSet() ?? {};
  }

  String get _timeText =>
      '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime() async {
    final time = await showTimePicker(context: context, initialTime: _time);
    if (time != null && mounted) setState(() => _time = time);
  }

  bool get _canSave => !_someDays || _days.isNotEmpty;

  void _save() {
    // All of the days is the same as following the habit.
    final all = !_someDays || _days.length == _offered.length;
    Navigator.pop(context, Reminder(time: _timeText, days: all ? null : (_days.toList()..sort())));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final due = widget.dueDays;
    return AlertDialog(
      title: Text(widget.initial == null ? 'New reminder' : 'Reminder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: _pickTime,
            icon: const Icon(Icons.schedule, size: 18),
            label: Text(_timeText, style: monoStyle(context, size: 17, medium: true)),
          ),
          // With a single day there is nothing to choose.
          if (_offered.length > 1) ...[
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(due == null ? 'Every day' : 'Every due day'),
                ),
                const ButtonSegment(value: true, label: Text('Some days')),
              ],
              showSelectedIcon: false,
              selected: {_someDays},
              onSelectionChanged: (choice) => setState(() => _someDays = choice.first),
            ),
            if (_someDays) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final day in _offered)
                    FilterChip(
                      label: Text(weekdayShort[day - 1]),
                      showCheckmark: false,
                      selected: _days.contains(day),
                      onSelected: (selected) => setState(() {
                        selected ? _days.add(day) : _days.remove(day);
                      }),
                    ),
                ],
              ),
            ] else if (due != null) ...[
              const SizedBox(height: 12),
              Text(
                _offered.map((day) => weekdayShort[day - 1]).join(', '),
                style: text.bodySmall!.copyWith(color: AppPalette.of(context).muted),
              ),
            ],
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _canSave ? _save : null, child: const Text('Save')),
      ],
    );
  }
}
