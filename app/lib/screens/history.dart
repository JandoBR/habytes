import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../platform/native.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'manage.dart';

const _cell = 20.0;
const _gap = 3.0;

/// A calendar heatmap of one habit's last 12 months.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, required this.habitId});

  final String habitId;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final DateTime _today = localToday();
  late final DateTime _first = _today.subtract(const Duration(days: 365));
  Habit? _habit;
  TodayHabit? _status;
  Map<String, int> _entries = {};
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final habits = await ref.read(habitsProvider.future);
      final habit = habits.where((h) => h.id == widget.habitId).firstOrNull;
      if (habit == null) throw Exception('This habit no longer exists.');
      final api = ref.read(apiProvider);
      final entries = await api.entries(habitId: habit.id, from: ymd(_first), to: ymd(_today));
      final status = await _fetchStatus(habit);
      if (mounted) {
        setState(() {
          _habit = habit;
          _entries = entries;
          _status = status;
        });
      }
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// The habit's row for today, which carries its streaks. Archived habits have none.
  Future<TodayHabit?> _fetchStatus(Habit habit) async {
    if (habit.archived) return null;
    final view = await ref.read(apiProvider).today(ymd(_today));
    return view.habits.where((h) => h.id == habit.id).firstOrNull;
  }

  Future<void> _edit(DateTime date) async {
    final habit = _habit!;
    final current = _entries[ymd(date)] ?? 0;
    final value = await showDialog<int>(
      context: context,
      builder: (context) => _ValueDialog(habit: habit, date: date, value: current),
    );
    if (value == null || value == current || !mounted) return;
    await guard(context, () async {
      final status = await ref.read(apiProvider).setValue(habit.id, ymd(date), value);
      final streaks = await _fetchStatus(habit);
      if (mounted) {
        setState(() {
          _entries = {..._entries, status.date: status.value};
          _status = streaks;
        });
      }
      ref.invalidate(todayProvider);
      Native.refreshWidgets();
    });
  }

  @override
  Widget build(BuildContext context) {
    final habit = _habit;
    return Scaffold(
      appBar: AppBar(
        title: Text(habit?.name ?? 'History'),
        actions: [
          if (habit != null)
            IconButton(
              tooltip: 'Edit habit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.pushReplacement('/habits/${habit.id}'),
            ),
        ],
      ),
      body: _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : habit == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(describeSchedule(habit), style: Theme.of(context).textTheme.titleMedium),
                if (habit.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(habit.description),
                ],
                if (_status != null) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: _Figure(
                          label: 'Current streak',
                          value: streakLength(_status!.streak, habit.schedule),
                          marked: _status!.streak > 0 && _status!.streak == _status!.bestStreak,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Figure(
                          label: 'Best streak',
                          value: streakLength(_status!.bestStreak, habit.schedule),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                _Heatmap(
                  habit: habit,
                  entries: _entries,
                  first: _first,
                  today: _today,
                  weekStart: ref.watch(userProvider).weekStart,
                  onTap: _edit,
                ),
                const SizedBox(height: 24),
                _Legend(
                  weekly: habit.schedule == Schedule.weekly,
                  hasOffDays: habit.weekdays != null,
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap a day to change its value.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}

/// A labelled number, highlighted when it is a record.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.marked = false});

  final String label;
  final String value;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: text.titleSmall!.copyWith(color: AppPalette.of(context).muted),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 5),
          child: Highlighted(value, on: marked, style: text.headlineSmall),
        ),
      ],
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({
    required this.habit,
    required this.entries,
    required this.first,
    required this.today,
    required this.weekStart,
    required this.onTap,
  });

  final Habit habit;
  final Map<String, int> entries;
  final DateTime first;
  final DateTime today;
  final int weekStart;
  final void Function(DateTime date) onTap;

  bool get _weekly => habit.schedule == Schedule.weekly;

  /// How full a day's cell is drawn, from 0 to 1.
  double _fill(int value) {
    if (value <= 0) return 0;
    // A weekly counter's goal is for the whole week; spread it over the days.
    final target = _weekly && habit.kind == HabitKind.counter ? habit.goal / 7 : 1.0;
    final perDay = _weekly ? target : habit.goal.toDouble();
    return (value / perDay).clamp(0.35, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;
    final gridStart = weekStartDate(first, weekStart);
    final weeks = (today.difference(gridStart).inDays ~/ 7) + 1;

    Widget cell(DateTime date) {
      if (date.isBefore(first) || date.isAfter(today)) {
        return const SizedBox(width: _cell + _gap, height: _cell + _gap);
      }
      final value = entries[ymd(date)] ?? 0;
      final due = habit.isDueOn(date);
      final Color color;
      if (value > 0) {
        color = colors.primary.withValues(alpha: _fill(value));
      } else if (due) {
        color = colors.surfaceContainerHighest;
      } else {
        // Not due and nothing logged: greyed out.
        color = colors.surfaceContainerHighest.withValues(alpha: 0.35);
      }
      return Tooltip(
        message: '${formatDate(date)}: $value${due ? '' : ' (not due)'}',
        child: GestureDetector(
          onTap: () => onTap(date),
          child: Container(
            width: _cell,
            height: _cell,
            margin: const EdgeInsets.all(_gap / 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
              border: date == today ? Border.all(color: colors.onSurface, width: 1.5) : null,
            ),
          ),
        ),
      );
    }

    /// Whether a week met its goal: null while it is still running or is cut
    /// off by the start of the range.
    Widget weekMarker(DateTime start) {
      final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
      final sum = days.fold(0, (total, day) => total + (entries[ymd(day)] ?? 0));
      final met = sum >= habit.goal;
      final complete = !start.isBefore(first) && !days.last.isAfter(today);
      return SizedBox(
        width: _cell + _gap,
        height: 14,
        child: Center(
          child: met
              ? Container(
                  width: 13,
                  height: 13,
                  color: colors.secondary,
                  child: Icon(Icons.check, size: 11, color: colors.onSecondary),
                )
              : complete
              ? Icon(Icons.close, size: 11, color: colors.onSurfaceVariant)
              : null,
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            const SizedBox(height: 18),
            for (var i = 0; i < 7; i++)
              SizedBox(
                height: _cell + _gap,
                width: 32,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(weekdayShort[(weekStart - 1 + i) % 7], style: small),
                ),
              ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // Start at the most recent weeks.
            reverse: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var week = 0; week < weeks; week++)
                  () {
                    final start = gridStart.add(Duration(days: week * 7));
                    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
                    final monthStart = days.where((d) => d.day == 1).firstOrNull;
                    return Column(
                      children: [
                        SizedBox(
                          height: 18,
                          width: _cell + _gap,
                          child: monthStart == null
                              ? null
                              : OverflowBox(
                                  maxWidth: 60,
                                  alignment: Alignment.centerLeft,
                                  child: Text(monthShort[monthStart.month - 1], style: small),
                                ),
                        ),
                        for (final day in days) cell(day),
                        if (_weekly) weekMarker(start),
                      ],
                    );
                  }(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.weekly, required this.hasOffDays});

  final bool weekly;
  final bool hasOffDays;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    Widget swatch(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Text(label, style: small),
      ],
    );

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        swatch(colors.primary, 'Logged'),
        swatch(colors.surfaceContainerHighest, 'Nothing logged'),
        if (hasOffDays) swatch(colors.surfaceContainerHighest.withValues(alpha: 0.35), 'Not due'),
        if (weekly) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                color: colors.secondary,
                child: Icon(Icons.check, size: 12, color: colors.onSecondary),
              ),
              const SizedBox(width: 6),
              Text('Week met', style: small),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close, size: 13, color: colors.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('Week missed', style: small),
            ],
          ),
        ],
      ],
    );
  }
}

/// Asks for one day's value: a switch for booleans, a number for counters.
class _ValueDialog extends StatefulWidget {
  const _ValueDialog({required this.habit, required this.date, required this.value});

  final Habit habit;
  final DateTime date;
  final int value;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final _controller = TextEditingController(text: '${widget.value}');
  late bool _checked = widget.value > 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = widget.habit.kind == HabitKind.boolean
        ? (_checked ? 1 : 0)
        : int.tryParse(_controller.text) ?? widget.value;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(formatDate(widget.date)),
    content: widget.habit.kind == HabitKind.boolean
        ? SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Done'),
            value: _checked,
            onChanged: (checked) => setState(() => _checked = checked),
          )
        : TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Value'),
            onSubmitted: (_) => _save(),
          ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
