import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../platform/native.dart';
import '../state/auth.dart';
import '../state/data.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'manage.dart';

const _cell = 20.0;
const _gap = 3.0;

/// One habit's record: streaks, figures, a calendar heatmap of the last 12
/// months, and its notes.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, required this.habitId});

  final String habitId;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  DateTime _today = localToday();
  DateTime get _first => _today.subtract(const Duration(days: 365));
  Habit? _habit;
  TodayHabit? _status;
  Map<String, DayEntry> _entries = {};
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
    final current = _entries[ymd(date)] ?? const DayEntry();
    final changed = await showDialog<DayEntry>(
      context: context,
      builder: (context) => _DayDialog(habit: habit, date: date, entry: current),
    );
    if (changed == null || !mounted) return;
    await guard(context, () async {
      final status = await ref
          .read(apiProvider)
          .setDay(
            habit.id,
            ymd(date),
            value: changed.value,
            skipped: changed.skipped,
            note: changed.note,
          );
      final streaks = await _fetchStatus(habit);
      if (mounted) {
        setState(() {
          _entries = {
            ..._entries,
            status.date: DayEntry(value: status.value, skipped: status.skipped, note: status.note),
          };
          _status = streaks;
        });
      }
      ref.invalidate(todayProvider);
      Native.refreshWidgets();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Left open past midnight: move on to the new day.
    ref.listen(currentDayProvider, (_, today) {
      setState(() => _today = today);
      _load();
    });
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
          : Centered(child: _body(context, habit)),
    );
  }

  Widget _body(BuildContext context, Habit habit) {
    final text = Theme.of(context).textTheme;
    final palette = AppPalette.of(context);
    final weekStart = ref.watch(userProvider).weekStart;
    final stats = computeStats(habit, _entries, _today, weekStart, since: _first);
    final ink = habitInk(context, habit.color);
    final target = habit.schedule.isTarget;
    final period = periodName(habit.schedule, habit.every);
    // Twelve weeks, or as many of a target's own periods as the year holds.
    final String trendTitle;
    if (!target || period == 'week') {
      trendTitle = 'LAST 12 WEEKS';
    } else if (stats.trend.length == 1) {
      trendTitle = 'THIS ${period.toUpperCase()}';
    } else {
      trendTitle = 'LAST ${stats.trend.length} ${period.toUpperCase()}S';
    }
    String percent(double? rate) => rate == null ? '–' : '${(rate * 100).round()}%';
    final notes = _entries.entries.where((e) => e.value.note.isNotEmpty).toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(describeSchedule(habit), style: text.titleMedium),
        if (habit.description.isNotEmpty) ...[const SizedBox(height: 4), Text(habit.description)],
        const SizedBox(height: 20),
        Wrap(
          spacing: 28,
          runSpacing: 16,
          children: [
            if (_status != null) ...[
              _Figure(
                label: 'Current streak',
                value: streakLength(_status!.streak, habit.schedule, habit.every),
                marked: _status!.streak > 0 && _status!.streak == _status!.bestStreak,
              ),
              _Figure(
                label: 'Best streak',
                value: streakLength(_status!.bestStreak, habit.schedule, habit.every),
              ),
            ],
            _Figure(label: 'Last 30 days', value: percent(stats.rate30)),
            _Figure(label: 'Last 90 days', value: percent(stats.rate90)),
            if (stats.bestWeekday != null)
              _Figure(label: 'Best day', value: weekdayNames[stats.bestWeekday! - 1]),
          ],
        ),
        const SizedBox(height: 24),
        Text(trendTitle, style: text.titleSmall!.copyWith(color: palette.muted)),
        const SizedBox(height: 8),
        _Trend(bars: stats.trend, color: ink),
        const SizedBox(height: 4),
        Text(
          target
              ? 'How far each $period got towards its goal.'
              : 'The share of due days done each week.',
          style: text.bodySmall!.copyWith(color: palette.muted),
        ),
        const SizedBox(height: 24),
        _Heatmap(
          habit: habit,
          entries: _entries,
          first: _first,
          today: _today,
          weekStart: weekStart,
          color: ink,
          onTap: _edit,
        ),
        const SizedBox(height: 16),
        _Legend(
          color: ink,
          period: target ? period : null,
          hasOffDays: habit.weekdays != null || habit.schedule == Schedule.interval,
          hasSkipped: _entries.values.any((e) => e.skipped),
        ),
        const SizedBox(height: 8),
        Text('Tap a day to change it, skip it or add a note.', style: text.bodySmall),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('NOTES', style: text.titleSmall!.copyWith(color: palette.muted)),
          const SizedBox(height: 4),
          for (final note in notes.take(30))
            InkWell(
              onTap: () => _edit(parseYmd(note.key)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 108,
                      child: Text(
                        formatDate(parseYmd(note.key)),
                        style: monoStyle(context, size: 12).copyWith(color: palette.muted),
                      ),
                    ),
                    Expanded(child: Text(note.value.note)),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 32),
      ],
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
      mainAxisSize: MainAxisSize.min,
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

/// A bar per week or period, oldest first.
class _Trend extends StatelessWidget {
  const _Trend({required this.bars, required this.color});

  final List<double> bars;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    const height = 56.0;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (index, week) in bars.indexed) ...[
            if (index > 0) const SizedBox(width: 4),
            Expanded(
              child: Tooltip(
                message: '${(week * 100).round()}%',
                child: Container(
                  height: height,
                  alignment: Alignment.bottomCenter,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: palette.line)),
                  ),
                  child: FractionallySizedBox(
                    heightFactor: week.clamp(0.0, 1.0),
                    child: Container(color: color),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
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
    required this.color,
    required this.onTap,
  });

  final Habit habit;
  final Map<String, DayEntry> entries;
  final DateTime first;
  final DateTime today;
  final int weekStart;
  final Color color;
  final void Function(DateTime date) onTap;

  bool get _target => habit.schedule.isTarget;

  (DateTime, DateTime) _period(DateTime day) =>
      periodBounds(habit.schedule, habit.every, day, weekStart);

  /// How full a day's cell is drawn, from 0 to 1.
  double _fill(int value) {
    if (value <= 0) return 0;
    if (!_target) return (value / habit.goal).clamp(0.35, 1.0);
    if (habit.kind == HabitKind.boolean) return 1;
    // A counter's target is for the whole period; spread it over the days.
    final (start, end) = _period(today);
    return (value * (end.difference(start).inDays + 1) / habit.goal).clamp(0.35, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final small = Theme.of(context).textTheme.labelSmall;
    final gridStart = weekStartDate(first, weekStart);
    final isDue = dueDays(habit, entries);
    final weeks = (today.difference(gridStart).inDays ~/ 7) + 1;

    Widget cell(DateTime date) {
      if (date.isBefore(first) || date.isAfter(today)) {
        return const SizedBox(width: _cell + _gap, height: _cell + _gap);
      }
      final entry = entries[ymd(date)] ?? const DayEntry();
      final due = isDue(date);
      final skipped = entry.skipped && entry.value == 0;
      final Color fill;
      if (entry.value > 0) {
        fill = color.withValues(alpha: _fill(entry.value));
      } else if (due && !skipped) {
        fill = palette.line;
      } else {
        // Not due, or excused, and nothing logged: greyed out.
        fill = palette.line.withValues(alpha: 0.35);
      }
      final unit = habit.unit.isEmpty ? '' : ' ${habit.unit}';
      return Tooltip(
        message: [
          '${formatDate(date)}: ${entry.value}$unit',
          if (skipped) 'skipped' else if (!due) 'not due',
          if (entry.note.isNotEmpty) entry.note,
        ].join('\n'),
        child: GestureDetector(
          onTap: () => onTap(date),
          child: Container(
            width: _cell,
            height: _cell,
            margin: const EdgeInsets.all(_gap / 2),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(2),
              border: date == today ? Border.all(color: colors.onSurface, width: 1.5) : null,
            ),
            child: skipped
                ? Center(child: Container(width: 8, height: 1.5, color: palette.muted))
                : entry.note.isNotEmpty
                ? Align(
                    alignment: Alignment.topRight,
                    // A dog-ear for days that carry a note.
                    child: Container(width: 5, height: 5, color: palette.highlight),
                  )
                : null,
          ),
        ),
      );
    }

    /// Whether the period that [day] is in met its goal: nothing while it is
    /// still running or is cut off by the start of the range.
    Widget? verdict(DateTime day) {
      final (start, end) = _period(day);
      var sum = 0, excused = false;
      for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
        sum += entries[ymd(d)]?.value ?? 0;
        excused = excused || (entries[ymd(d)]?.skipped ?? false);
      }
      if (sum >= habit.goal) {
        return Container(
          width: 13,
          height: 13,
          color: colors.secondary,
          child: Icon(Icons.check, size: 11, color: colors.onSecondary),
        );
      }
      final complete = !start.isBefore(first) && !end.isAfter(today);
      if (!complete || excused) return null;
      return Icon(Icons.close, size: 11, color: colors.onSurfaceVariant);
    }

    /// The mark under a week: for the period that ends in it, or for the
    /// running one under today's week once it is met.
    Widget periodMarker(List<DateTime> days) {
      final last = days.where((day) => !day.isAfter(today) && _period(day).$2 == day).firstOrNull;
      return SizedBox(
        width: _cell + _gap,
        height: 14,
        child: Center(
          child:
              (last == null ? null : verdict(last)) ??
              (days.contains(today) ? verdict(today) : null),
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
                        if (_target) periodMarker(days),
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
  const _Legend({
    required this.color,
    required this.period,
    required this.hasOffDays,
    required this.hasSkipped,
  });

  final Color color;

  /// What a target's period is called; null for a habit that has a goal per day.
  final String? period;
  final bool hasOffDays;
  final bool hasSkipped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final period = this.period;
    final name = period == null ? '' : period[0].toUpperCase() + period.substring(1);

    Widget item(Widget mark, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 6),
        Text(label, style: small),
      ],
    );
    Widget swatch(Color fill, [Widget? child]) => Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(2)),
      child: child,
    );

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        item(swatch(color), 'Logged'),
        item(swatch(palette.line), 'Nothing logged'),
        if (hasOffDays) item(swatch(palette.line.withValues(alpha: 0.35)), 'Not due'),
        if (hasSkipped)
          item(
            swatch(
              palette.line.withValues(alpha: 0.35),
              Center(child: Container(width: 6, height: 1.5, color: palette.muted)),
            ),
            'Skipped',
          ),
        if (period != null) ...[
          item(
            Container(
              width: 14,
              height: 14,
              color: colors.secondary,
              child: Icon(Icons.check, size: 12, color: colors.onSecondary),
            ),
            '$name met',
          ),
          item(Icon(Icons.close, size: 13, color: colors.onSurfaceVariant), '$name missed'),
        ],
      ],
    );
  }
}

/// Changes one day: its value (a switch for yes/no habits, a number for
/// counters), whether it is skipped, and its note.
class _DayDialog extends StatefulWidget {
  const _DayDialog({required this.habit, required this.date, required this.entry});

  final Habit habit;
  final DateTime date;
  final DayEntry entry;

  @override
  State<_DayDialog> createState() => _DayDialogState();
}

class _DayDialogState extends State<_DayDialog> {
  late final _value = TextEditingController(text: '${widget.entry.value}');
  late final _note = TextEditingController(text: widget.entry.note);
  late bool _checked = widget.entry.value > 0;
  late bool _skipped = widget.entry.skipped;

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final value = widget.habit.kind == HabitKind.boolean
        ? (_checked ? 1 : 0)
        : int.tryParse(_value.text) ?? widget.entry.value;
    Navigator.pop(context, DayEntry(value: value, skipped: _skipped, note: _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(formatDate(widget.date)),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.habit.kind == HabitKind.boolean)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Done'),
              value: _checked,
              onChanged: (checked) => setState(() => _checked = checked),
            )
          else
            TextField(
              controller: _value,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: widget.habit.unit.isEmpty ? 'Value' : widget.habit.unit,
              ),
              onSubmitted: (_) => _save(),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Skipped'),
            subtitle: const Text('Does not break the streak'),
            value: _skipped,
            onChanged: (skipped) => setState(() => _skipped = skipped),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            maxLength: 500,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note', counterText: ''),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
