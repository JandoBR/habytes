import 'api/models.dart';

/// Figures about one habit, worked out from its days.
class HabitStats {
  const HabitStats({
    required this.rate30,
    required this.rate90,
    required this.bestWeekday,
    required this.trend,
  });

  /// The share of counted periods that were done, 0 to 1; null with nothing to count.
  final double? rate30;
  final double? rate90;

  /// The weekday it most often gets done on, 1 = Monday ... 7 = Sunday.
  final int? bestWeekday;

  /// How well each of the last weeks went, oldest first, 0 to 1: twelve of
  /// them, or for a target as many of its own periods as there are days for.
  final List<double> trend;
}

/// Whether [habit] was due on a day: on its weekdays, and for an interval not
/// while it rests after one of the days in [entries] it was done on.
bool Function(DateTime day) dueDays(Habit habit, Map<String, DayEntry> entries) {
  if (habit.schedule != Schedule.interval) return habit.isDueOn;
  final resting = <String>{};
  for (final MapEntry(:key, :value) in entries.entries) {
    if (value.value < habit.goal) continue;
    for (var i = 1; i < habit.every; i++) {
      resting.add(ymd(parseYmd(key).add(Duration(days: i))));
    }
  }
  return (day) => !resting.contains(ymd(day));
}

/// [since] is the first day there are [entries] for, when earlier ones were
/// left out: a period that began before it cannot be judged.
HabitStats computeStats(
  Habit habit,
  Map<String, DayEntry> entries,
  DateTime today,
  int weekStart, {
  DateTime? since,
}) {
  final target = habit.schedule.isTarget;
  final isDue = dueDays(habit, entries);
  DayEntry on(DateTime day) => entries[ymd(day)] ?? const DayEntry();
  bool doneOn(DateTime day) => on(day).value >= habit.goal;

  // The habit cannot be missed before it existed: its first day is the day it
  // was made, or the first day logged if that was filled in for earlier.
  DateTime? first;
  final created = habit.createdAt?.toLocal();
  if (created != null) {
    first = DateTime.utc(created.year, created.month, created.day);
    for (final MapEntry(:key, :value) in entries.entries) {
      final day = parseYmd(key);
      if ((value.value > 0 || value.skipped) && day.isBefore(first!)) first = day;
    }
  }
  bool existedOn(DateTime day) => first == null || !day.isBefore(first);

  /// Done and counted days in `[from, to]`. Skipped and off days are left
  /// out, and so is today while it is still open.
  (int, int) days(DateTime from, DateTime to) {
    var done = 0, counted = 0;
    for (var day = from; !day.isAfter(to); day = day.add(const Duration(days: 1))) {
      final isDone = doneOn(day);
      if (isDone) {
        done++;
        counted++;
      } else if (isDue(day) && !on(day).skipped && day != today && existedOn(day)) {
        counted++;
      }
    }
    return (done, counted);
  }

  /// The share of due days done in the week from [start].
  double week(DateTime start) {
    final end = start.add(const Duration(days: 6));
    final (done, counted) = days(start, end.isAfter(today) ? today : end);
    return counted == 0 ? 0 : done / counted;
  }

  /// How far a target's period got towards the goal, and whether it counts at all.
  (double, bool) period(DateTime start, DateTime end) {
    var sum = 0, excused = false;
    for (var day = start; !day.isAfter(end); day = day.add(const Duration(days: 1))) {
      sum += on(day).value;
      excused = excused || on(day).skipped;
    }
    final met = sum >= habit.goal;
    final running = !end.isBefore(today);
    // The period it was made in is cut short, and so is one the entries only
    // partly cover: those only count if they were met.
    final whole = existedOn(start) && !(since != null && start.isBefore(since));
    return ((sum / habit.goal).clamp(0, 1).toDouble(), met || !(running || excused || !whole));
  }

  /// The running period and the ones before it, newest first.
  Iterable<(DateTime, DateTime)> periods() sync* {
    var day = today;
    while (true) {
      final bounds = periodBounds(habit.schedule, habit.every, day, weekStart);
      yield bounds;
      day = bounds.$1.subtract(const Duration(days: 1));
    }
  }

  final thisWeek = weekStartDate(today, weekStart);
  DateTime weeksAgo(int n) => thisWeek.subtract(Duration(days: 7 * n));

  double? rate(int span) {
    if (!target) {
      final (done, counted) = days(today.subtract(Duration(days: span - 1)), today);
      return counted == 0 ? null : done / counted;
    }
    // As many periods as fit in the span, and at least the running one and
    // the one before it.
    final (start, end) = periodBounds(habit.schedule, habit.every, today, weekStart);
    final length = end.difference(start).inDays + 1;
    var met = 0, counted = 0;
    for (final (start, end) in periods().take((span / length).round().clamp(2, span))) {
      final (progress, counts) = period(start, end);
      if (counts) {
        counted++;
        if (progress >= 1) met++;
      }
    }
    return counted == 0 ? null : met / counted;
  }

  // A target's trend goes back period by period, as far as the entries do.
  final trend = <double>[];
  if (target) {
    for (final (start, end) in periods().take(12)) {
      if (trend.isNotEmpty && since != null && start.isBefore(since)) break;
      trend.insert(0, period(start, end).$1);
    }
  } else {
    trend.addAll([for (var n = 11; n >= 0; n--) week(weeksAgo(n))]);
  }

  // The weekday with the best record over the last 90 days.
  final hits = List.filled(8, 0), chances = List.filled(8, 0);
  for (var i = 0; i < 90; i++) {
    final day = today.subtract(Duration(days: i));
    final logged = target ? on(day).value > 0 : doneOn(day);
    if (logged) hits[day.weekday]++;
    if (logged || (isDue(day) && !on(day).skipped && existedOn(day))) {
      chances[day.weekday]++;
    }
  }
  int? best;
  var bestScore = 0.0;
  for (var weekday = 1; weekday <= 7; weekday++) {
    if (hits[weekday] == 0) continue;
    // Targets are logged whenever, so the plain count is what matters.
    final score = target ? hits[weekday].toDouble() : hits[weekday] / chances[weekday];
    if (score > bestScore) {
      bestScore = score;
      best = weekday;
    }
  }

  return HabitStats(rate30: rate(30), rate90: rate(90), bestWeekday: best, trend: trend);
}
