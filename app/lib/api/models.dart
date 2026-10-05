/// A calendar day with no time zone, as the API uses it (`YYYY-MM-DD`).
String ymd(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Parses `YYYY-MM-DD` into a UTC midnight, which keeps date arithmetic free of DST.
DateTime parseYmd(String value) {
  final parts = value.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}

/// The device's current calendar day, as a UTC midnight.
DateTime localToday() {
  final now = DateTime.now();
  return DateTime.utc(now.year, now.month, now.day);
}

/// The first day of the week containing [date], for weeks starting on
/// [weekStart] (1 = Monday ... 7 = Sunday).
DateTime weekStartDate(DateTime date, int weekStart) =>
    date.subtract(Duration(days: (date.weekday - weekStart) % 7));

enum HabitKind { boolean, counter }

enum Schedule { daily, weekdays, weekly }

/// `12 days`, `1 week`: a streak's length in the habit's own period.
String streakLength(int streak, Schedule schedule) {
  final unit = schedule == Schedule.weekly ? 'week' : 'day';
  return '$streak $unit${streak == 1 ? '' : 's'}';
}

class User {
  const User({
    required this.id,
    required this.username,
    required this.timezone,
    required this.weekStart,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as String,
    username: json['username'] as String,
    timezone: json['timezone'] as String,
    weekStart: json['week_start'] as int,
  );

  final String id;
  final String username;
  final String timezone;
  final int weekStart;
}

class Habit {
  const Habit({
    required this.id,
    required this.name,
    required this.description,
    required this.kind,
    required this.schedule,
    required this.weekdays,
    required this.goal,
    required this.position,
    required this.archived,
    required this.webhookUrl,
  });

  factory Habit.fromJson(Map<String, dynamic> json) => Habit(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String,
    kind: HabitKind.values.byName(json['kind'] as String),
    schedule: Schedule.values.byName(json['schedule'] as String),
    weekdays: (json['weekdays'] as List?)?.cast<int>(),
    goal: json['goal'] as int,
    position: json['position'] as int,
    archived: json['archived'] as bool,
    webhookUrl: json['webhook_url'] as String?,
  );

  final String id;
  final String name;
  final String description;
  final HabitKind kind;
  final Schedule schedule;

  /// Day numbers, 1 = Monday ... 7 = Sunday. Only for [Schedule.weekdays].
  final List<int>? weekdays;
  final int goal;
  final int position;
  final bool archived;
  final String? webhookUrl;

  bool isDueOn(DateTime date) => weekdays?.contains(date.weekday) ?? true;
}

/// A habit's status on one day, returned by every write.
class EntryStatus {
  const EntryStatus({
    required this.habitId,
    required this.date,
    required this.value,
    required this.periodValue,
    required this.done,
    required this.streak,
    required this.bestStreak,
  });

  factory EntryStatus.fromJson(Map<String, dynamic> json) => EntryStatus(
    habitId: json['habit_id'] as String,
    date: json['date'] as String,
    value: json['value'] as int,
    periodValue: json['period_value'] as int,
    done: json['done'] as bool,
    streak: json['streak'] as int? ?? 0,
    bestStreak: json['best_streak'] as int? ?? 0,
  );

  final String habitId;
  final String date;
  final int value;
  final int periodValue;
  final bool done;

  /// Periods done in a row: due days, or weeks for a weekly habit.
  final int streak;
  final int bestStreak;
}

/// One row of `GET /today`.
class TodayHabit {
  const TodayHabit({
    required this.id,
    required this.name,
    required this.kind,
    required this.schedule,
    required this.goal,
    required this.due,
    required this.value,
    required this.periodValue,
    required this.done,
    required this.streak,
    required this.bestStreak,
  });

  factory TodayHabit.fromJson(Map<String, dynamic> json) => TodayHabit(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: HabitKind.values.byName(json['kind'] as String),
    schedule: Schedule.values.byName(json['schedule'] as String),
    goal: json['goal'] as int,
    due: json['due'] as bool,
    value: json['value'] as int,
    periodValue: json['period_value'] as int,
    done: json['done'] as bool,
    streak: json['streak'] as int? ?? 0,
    bestStreak: json['best_streak'] as int? ?? 0,
  );

  final String id;
  final String name;
  final HabitKind kind;
  final Schedule schedule;
  final int goal;
  final bool due;

  /// The day's own value.
  final int value;

  /// What completion is measured on: [value], or the week's sum for weekly habits.
  final int periodValue;
  final bool done;

  /// Periods done in a row: due days, or weeks for a weekly habit.
  final int streak;
  final int bestStreak;

  TodayHabit withStatus(EntryStatus status) => TodayHabit(
    id: id,
    name: name,
    kind: kind,
    schedule: schedule,
    goal: goal,
    due: due,
    value: status.value,
    periodValue: status.periodValue,
    done: status.done,
    streak: status.streak,
    bestStreak: status.bestStreak,
  );

  /// `3/8 today`, `2/3 this week`, or nothing for a plain daily checkbox.
  String get progress {
    if (schedule == Schedule.weekly) return '$periodValue/$goal this week';
    if (kind == HabitKind.counter) return '$value/$goal today';
    return '';
  }
}

class TodayView {
  const TodayView({required this.date, required this.weekStartDate, required this.habits});

  factory TodayView.fromJson(Map<String, dynamic> json) => TodayView(
    date: json['date'] as String,
    weekStartDate: json['week_start_date'] as String,
    habits: (json['habits'] as List)
        .map((h) => TodayHabit.fromJson(h as Map<String, dynamic>))
        .toList(),
  );

  final String date;
  final String weekStartDate;
  final List<TodayHabit> habits;

  TodayView withStatus(EntryStatus status) => TodayView(
    date: date,
    weekStartDate: weekStartDate,
    habits: [
      for (final habit in habits)
        if (habit.id == status.habitId) habit.withStatus(status) else habit,
    ],
  );
}

class TokenInfo {
  const TokenInfo({
    required this.id,
    required this.kind,
    required this.name,
    required this.createdAt,
    required this.lastUsedAt,
    required this.expiresAt,
    required this.current,
  });

  factory TokenInfo.fromJson(Map<String, dynamic> json) => TokenInfo(
    id: json['id'] as String,
    kind: json['kind'] as String,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    lastUsedAt: DateTime.tryParse(json['last_used_at'] as String? ?? ''),
    expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
    current: json['current'] as bool,
  );

  final String id;

  /// `session`, `device` or `api`.
  final String kind;
  final String name;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final bool current;
}
