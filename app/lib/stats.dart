import 'api/models.dart';

/// Figures about one habit, worked out from its days.
class HabitStats {
  const HabitStats({
    required this.rate30,
    required this.rate90,
    required this.bestWeekday,
    required this.weeks,
  });

  /// The share of counted periods that were done, 0 to 1; null with nothing to count.
  final double? rate30;
  final double? rate90;

  /// The weekday it most often gets done on, 1 = Monday ... 7 = Sunday.
  final int? bestWeekday;

  /// How well each of the last twelve weeks went, oldest first, 0 to 1.
  final List<double> weeks;
}

HabitStats computeStats(Habit habit, Map<String, DayEntry> entries, DateTime today, int weekStart) {
  final weekly = habit.schedule == Schedule.weekly;
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
      } else if (habit.isDueOn(day) && !on(day).skipped && day != today && existedOn(day)) {
        counted++;
      }
    }
    return (done, counted);
  }

  /// How far a week got towards the goal, and whether it counts at all.
  (double, bool) week(DateTime start) {
    final all = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    if (!weekly) {
      final (done, counted) = days(start, all.last.isAfter(today) ? today : all.last);
      return (counted == 0 ? 0 : done / counted, counted > 0);
    }
    final sum = all.fold(0, (total, day) => total + on(day).value);
    final met = sum >= habit.goal;
    final running = !all.last.isBefore(today);
    final excused = all.any((day) => on(day).skipped);
    // The week it was made in is cut short, so it only counts if it was met.
    final whole = existedOn(start);
    return ((sum / habit.goal).clamp(0, 1).toDouble(), met || !(running || excused || !whole));
  }

  final thisWeek = weekStartDate(today, weekStart);
  DateTime weeksAgo(int n) => thisWeek.subtract(Duration(days: 7 * n));

  double? rate(int span) {
    if (!weekly) {
      final (done, counted) = days(today.subtract(Duration(days: span - 1)), today);
      return counted == 0 ? null : done / counted;
    }
    var met = 0, counted = 0;
    for (var n = 0; n < (span / 7).round(); n++) {
      final (progress, counts) = week(weeksAgo(n));
      if (counts) {
        counted++;
        if (progress >= 1) met++;
      }
    }
    return counted == 0 ? null : met / counted;
  }

  // The weekday with the best record over the last 90 days.
  final hits = List.filled(8, 0), chances = List.filled(8, 0);
  for (var i = 0; i < 90; i++) {
    final day = today.subtract(Duration(days: i));
    final logged = weekly ? on(day).value > 0 : doneOn(day);
    if (logged) hits[day.weekday]++;
    if (logged || (habit.isDueOn(day) && !on(day).skipped && existedOn(day))) chances[day.weekday]++;
  }
  int? best;
  var bestScore = 0.0;
  for (var weekday = 1; weekday <= 7; weekday++) {
    if (hits[weekday] == 0) continue;
    // Weekly habits are logged whenever, so the plain count is what matters.
    final score = weekly ? hits[weekday].toDouble() : hits[weekday] / chances[weekday];
    if (score > bestScore) {
      bestScore = score;
      best = weekday;
    }
  }

  return HabitStats(
    rate30: rate(30),
    rate90: rate(90),
    bestWeekday: best,
    weeks: [for (var n = 11; n >= 0; n--) week(weeksAgo(n)).$1],
  );
}
