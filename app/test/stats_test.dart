import 'package:flutter_test/flutter_test.dart';
import 'package:habytes/api/models.dart';
import 'package:habytes/stats.dart';

// 2026-10-05 is a Monday.
final monday = DateTime.utc(2026, 10, 5);

Habit habit({
  HabitKind kind = HabitKind.boolean,
  Schedule schedule = Schedule.daily,
  int every = 1,
  List<int>? weekdays,
  int goal = 1,
  DateTime? createdAt,
}) => Habit(
  id: 'a',
  name: 'Habit',
  description: '',
  kind: kind,
  schedule: schedule,
  every: every,
  weekdays: weekdays,
  goal: goal,
  position: 0,
  archived: false,
  webhookUrl: null,
  unit: '',
  color: 'ink',
  categoryId: null,
  reminders: const [],
  createdAt: createdAt,
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
    expect(stats.trend.last, 1.0);
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
    expect(stats.trend.sublist(9), [0.5, 1.0, 0.0]);
  });

  test('days before the habit was made are not held against it', () {
    // Made on Thursday the 1st and done every day since.
    final made = DateTime(2026, 10, 1, 9);
    final entries = log({
      for (final offset in [-4, -3, -2, -1]) offset: const DayEntry(value: 1),
    });
    final stats = computeStats(habit(createdAt: made), entries, monday, 1);
    expect(stats.rate30, 1.0);
    expect(stats.rate90, 1.0);
    expect(stats.trend.sublist(10), [1.0, 0.0]);

    // A day filled in for before it was made moves its first day back.
    final earlier = {
      ...entries,
      ...log({-8: const DayEntry(value: 1)}),
    };
    expect(computeStats(habit(createdAt: made), earlier, monday, 1).rate30, closeTo(5 / 8, 1e-9));

    // A weekly habit's first, partial week only counts if it was met.
    final weekly = habit(schedule: Schedule.weekly, goal: 3, createdAt: made);
    expect(computeStats(weekly, log({-3: const DayEntry(value: 1)}), monday, 1).rate30, isNull);
  });

  test('nothing logged gives no rate and no best day', () {
    final stats = computeStats(habit(schedule: Schedule.weekly, goal: 2), {}, monday, 1);
    expect(stats.bestWeekday, isNull);
    expect(stats.trend, List.filled(12, 0.0));
  });

  test('periods follow the calendar', () {
    (String, String) bounds(Schedule schedule, int every, DateTime day) {
      final (start, end) = periodBounds(schedule, every, day, 1);
      return (ymd(start), ymd(end));
    }

    final wednesday = DateTime.utc(2026, 10, 7);
    expect(bounds(Schedule.daily, 1, wednesday), ('2026-10-07', '2026-10-07'));
    expect(bounds(Schedule.weekly, 1, wednesday), ('2026-10-05', '2026-10-11'));
    expect(bounds(Schedule.monthly, 1, DateTime.utc(2028, 2, 14)), ('2028-02-01', '2028-02-29'));
    expect(bounds(Schedule.monthly, 3, DateTime.utc(2026, 11, 30)), ('2026-10-01', '2026-12-31'));
    expect(bounds(Schedule.yearly, 1, wednesday), ('2026-01-01', '2026-12-31'));
    expect(bounds(Schedule.yearly, 2, DateTime.utc(2027, 6, 1)), ('2026-01-01', '2027-12-31'));

    // Two weeks are one block, whichever day the week starts on.
    for (var weekStart = 1; weekStart <= 7; weekStart++) {
      final (start, end) = periodBounds(Schedule.weekly, 2, wednesday, weekStart);
      expect(start, weekStartDate(start, weekStart));
      expect(end.difference(start).inDays, 13);
      expect(periodBounds(Schedule.weekly, 2, end, weekStart), (start, end));
      final next = end.add(const Duration(days: 1));
      expect(periodBounds(Schedule.weekly, 2, next, weekStart).$1, next);
    }
  });

  test('monthly targets are rated in months', () {
    final monthly = habit(schedule: Schedule.monthly, goal: 2);
    final entries = {
      // September met, August one short, July met.
      '2026-09-03': const DayEntry(value: 1),
      '2026-09-28': const DayEntry(value: 1),
      '2026-08-10': const DayEntry(value: 1),
      '2026-07-01': const DayEntry(value: 2),
      '2026-10-02': const DayEntry(value: 1),
    };
    final stats = computeStats(monthly, entries, monday, 1);
    // October is still running, which leaves September, and August with it.
    expect(stats.rate30, 1.0);
    expect(stats.rate90, 0.5);
    expect(stats.trend.sublist(8), [1.0, 0.5, 1.0, 0.5]);
    expect(streakLength(3, Schedule.monthly), '3 months');
    expect(streakLength(1, Schedule.monthly, 3), '1 quarter');
    expect(streakLength(2, Schedule.weekly, 2), '2 periods');
  });

  test('a period the entries only partly cover is not judged', () {
    final yearly = habit(schedule: Schedule.yearly, goal: 3);
    final since = monday.subtract(const Duration(days: 365));
    final entries = {'2026-03-01': const DayEntry(value: 1)};
    final stats = computeStats(yearly, entries, monday, 1, since: since);
    // Only this year is known in full, and it is still running.
    expect(stats.rate90, isNull);
    expect(stats.trend, [closeTo(1 / 3, 1e-9)]);
  });

  test('an interval habit is only held to the days it was due', () {
    final plants = habit(schedule: Schedule.interval, every: 3);
    // Done three days apart, then left for five days and done late.
    final entries = log({
      for (final offset in [-14, -11, -8, -3]) offset: const DayEntry(value: 1),
    });
    final isDue = dueDays(plants, entries);
    expect(isDue(monday.subtract(const Duration(days: 10))), isFalse);
    expect(isDue(monday.subtract(const Duration(days: 5))), isTrue);
    final made = DateTime(2026, 9, 21, 9);
    final stats = computeStats(
      habit(schedule: Schedule.interval, every: 3, createdAt: made),
      entries,
      monday,
      1,
    );
    // Four times done, and the two days it sat overdue.
    expect(stats.rate30, closeTo(4 / 6, 1e-9));
    expect(streakLength(4, Schedule.interval, 3), '4 times');
  });
}
