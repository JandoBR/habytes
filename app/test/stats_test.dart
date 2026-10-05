import 'package:flutter_test/flutter_test.dart';
import 'package:habytes/api/models.dart';
import 'package:habytes/stats.dart';

// 2026-10-05 is a Monday.
final monday = DateTime.utc(2026, 10, 5);

Habit habit({
  HabitKind kind = HabitKind.boolean,
  Schedule schedule = Schedule.daily,
  List<int>? weekdays,
  int goal = 1,
}) => Habit(
  id: 'a',
  name: 'Habit',
  description: '',
  kind: kind,
  schedule: schedule,
  weekdays: weekdays,
  goal: goal,
  position: 0,
  archived: false,
  webhookUrl: null,
  unit: '',
  color: 'ink',
  categoryId: null,
  reminders: const [],
);

/// Entries by offset in days from [monday]; negative is before it.
Map<String, DayEntry> log(Map<int, DayEntry> days) => {
  for (final MapEntry(:key, :value) in days.entries) ymd(monday.add(Duration(days: key))): value,
};

void main() {
  test('rates count done days out of due days', () {
    // Ten days back from Monday the 5th, done on six of them.
    final entries = log({
      for (final offset in [-9, -8, -7, -5, -3, -1]) offset: const DayEntry(value: 1),
    });
    final stats = computeStats(habit(), entries, monday, 1);
    // Today is still open, so 29 days count.
    expect(stats.rate30, closeTo(6 / 29, 1e-9));
    expect(stats.rate90, closeTo(6 / 89, 1e-9));
  });

  test('skipped and off days are left out', () {
    final weekdays = habit(schedule: Schedule.weekdays, weekdays: [1, 3]);
    final entries = log({
      -7: const DayEntry(value: 1), // Monday
      -5: const DayEntry(skipped: true), // Wednesday, excused
    });
    final stats = computeStats(weekdays, entries, monday.subtract(const Duration(days: 4)), 1);
    // The week so far: Monday done, Wednesday skipped. Earlier weeks: nothing.
    expect(stats.weeks.last, 1.0);
    expect(stats.bestWeekday, DateTime.monday);
  });

  test('a counter day counts only once the goal is met', () {
    final counter = habit(kind: HabitKind.counter, goal: 8);
    final entries = log({-1: const DayEntry(value: 8), -2: const DayEntry(value: 7)});
    final stats = computeStats(counter, entries, monday, 1);
    expect(stats.rate30, closeTo(1 / 29, 1e-9));
  });

  test('weekly habits are rated in weeks', () {
    final weekly = habit(schedule: Schedule.weekly, goal: 2);
    final entries = log({
      // Last week: met. The week before: one day only.
      -7: const DayEntry(value: 1),
      -6: const DayEntry(value: 1),
      -14: const DayEntry(value: 1),
    });
    final stats = computeStats(weekly, entries, monday, 1);
    // The running week is not held against it; two finished weeks, one met.
    expect(stats.rate30, closeTo(1 / 3, 1e-9));
    expect(stats.weeks.sublist(9), [0.5, 1.0, 0.0]);
  });

  test('nothing logged gives no rate and no best day', () {
    final stats = computeStats(habit(schedule: Schedule.weekly, goal: 2), {}, monday, 1);
    expect(stats.bestWeekday, isNull);
    expect(stats.weeks, List.filled(12, 0.0));
  });
}
