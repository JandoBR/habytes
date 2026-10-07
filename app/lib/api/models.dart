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

enum Schedule {
  daily,
  weekdays,
  weekly,
  monthly,
  yearly,

  /// Due again some days after it was last done.
  interval;

  /// Whether the goal is for a whole period (a week, a month, a year, or
  /// several of them) rather than for each day.
  bool get isTarget => this == weekly || this == monthly || this == yearly;

  /// `week`, `month`, `year`: what a target's period is made of.
  String get unit => switch (this) {
    weekly => 'week',
    monthly => 'month',
    yearly => 'year',
    daily || weekdays || interval => 'day',
  };
}

/// `week`, `quarter`, `period`: what one period of a schedule is called, where
/// [every] weeks, months or years count as one. An interval is counted in times.
String periodName(Schedule schedule, [int every = 1]) => switch ((schedule, every)) {
  (Schedule.interval, _) => 'time',
  (_, 1) => schedule.unit,
  (Schedule.monthly, 3) => 'quarter',
  _ => 'period',
};

/// `a week`, `every 3 months`: how often a target comes round.
String periodRate(Schedule schedule, [int every = 1]) =>
    every == 1 ? 'a ${schedule.unit}' : 'every $every ${schedule.unit}s';

/// The first and last day of the period containing [date]. Several weeks are
/// counted in blocks from a fixed week, several months from January, so that
/// three months are a calendar quarter.
(DateTime, DateTime) periodBounds(Schedule schedule, int every, DateTime date, int weekStart) {
  switch (schedule) {
    case Schedule.daily || Schedule.weekdays || Schedule.interval:
      return (date, date);
    case Schedule.weekly:
      // 1970-01-05 is a Monday; any fixed week would do.
      final origin = weekStartDate(DateTime.utc(1970, 1, 5), weekStart);
      final week = weekStartDate(date, weekStart);
      final weeks = week.difference(origin).inDays ~/ 7;
      final start = week.subtract(Duration(days: (weeks % every) * 7));
      return (start, start.add(Duration(days: every * 7 - 1)));
    case Schedule.monthly || Schedule.yearly:
      final months = schedule == Schedule.yearly ? every * 12 : every;
      final month = date.year * 12 + date.month - 1;
      final first = month - month % months;
      // Day 0 of a month is the last day of the one before.
      return (
        DateTime.utc(first ~/ 12, first % 12 + 1),
        DateTime.utc(first ~/ 12, first % 12 + 1 + months, 0),
      );
  }
}

/// When to remind about a habit: a local time of day, on every day or only on
/// some weekdays.
class Reminder {
  const Reminder({required this.time, this.days});

  factory Reminder.fromJson(Map<String, dynamic> json) =>
      Reminder(time: json['time'] as String, days: (json['days'] as List?)?.cast<int>());

  /// `HH:MM`.
  final String time;

  /// Day numbers, 1 = Monday ... 7 = Sunday; null for every day.
  final List<int>? days;

  Map<String, Object?> toJson() => {'time': time, 'days': days};

  /// The reminder for a habit that is only due on [due] (null for every day):
  /// without the days the habit is not due on, and on every due day if that
  /// leaves none or all of them.
  Reminder fitTo(Set<int>? due) {
    final days = this.days;
    if (days == null) return this;
    final kept = [
      for (final day in days)
        if (due?.contains(day) ?? true) day,
    ];
    final all = kept.isEmpty || kept.length == (due?.length ?? 7);
    return Reminder(time: time, days: all ? null : kept);
  }

  /// `Every day`, `Mon, Wed, Fri`: the days it goes off on, for a habit that is
  /// only due on [due] (null for every day).
  String daysText([Set<int>? due]) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final days = fitTo(due).days ?? (due?.toList()?..sort());
    if (days == null || days.length == 7) return 'Every day';
    return days.map((d) => names[d - 1]).join(', ');
  }
}

/// The inks a habit can be drawn in; `ink` is the app's own.
const habitColors = ['ink', 'red', 'green', 'violet', 'orange', 'teal'];

/// `12 days`, `1 week`: a streak's length in the habit's own period.
String streakLength(int streak, Schedule schedule, [int every = 1]) =>
    '$streak ${periodName(schedule, every)}${streak == 1 ? '' : 's'}';

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
    this.every = 1,
    required this.weekdays,
    required this.goal,
    required this.position,
    required this.archived,
    required this.webhookUrl,
    required this.unit,
    required this.color,
    required this.categoryId,
    required this.reminders,
    this.createdAt,
  });

  factory Habit.fromJson(Map<String, dynamic> json) => Habit(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String,
    kind: HabitKind.values.byName(json['kind'] as String),
    schedule: Schedule.values.byName(json['schedule'] as String),
    every: json['every'] as int? ?? 1,
    weekdays: (json['weekdays'] as List?)?.cast<int>(),
    goal: json['goal'] as int,
    position: json['position'] as int,
    archived: json['archived'] as bool,
    webhookUrl: json['webhook_url'] as String?,
    unit: json['unit'] as String? ?? '',
    color: json['color'] as String? ?? 'ink',
    categoryId: json['category_id'] as String?,
    reminders: ((json['reminders'] as List?) ?? const [])
        .map((r) => Reminder.fromJson(r as Map<String, dynamic>))
        .toList(),
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
  );

  final String id;
  final String name;
  final String description;
  final HabitKind kind;
  final Schedule schedule;

  /// How many weeks, months or years a target's period spans, or the days of
  /// an interval; 1 otherwise.
  final int every;

  /// Day numbers, 1 = Monday ... 7 = Sunday. Only for [Schedule.weekdays].
  final List<int>? weekdays;
  final int goal;
  final int position;
  final bool archived;
  final String? webhookUrl;

  /// What a counter counts: `pages`, `ml`. May be empty.
  final String unit;

  /// One of [habitColors].
  final String color;
  final String? categoryId;

  final List<Reminder> reminders;

  /// When the habit was made, if the server said.
  final DateTime? createdAt;

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
    required this.skipped,
    required this.note,
    required this.streak,
    required this.bestStreak,
  });

  factory EntryStatus.fromJson(Map<String, dynamic> json) => EntryStatus(
    habitId: json['habit_id'] as String,
    date: json['date'] as String,
    value: json['value'] as int,
    periodValue: json['period_value'] as int,
    done: json['done'] as bool,
    skipped: json['skipped'] as bool? ?? false,
    note: json['note'] as String? ?? '',
    streak: json['streak'] as int? ?? 0,
    bestStreak: json['best_streak'] as int? ?? 0,
  );

  final String habitId;
  final String date;
  final int value;
  final int periodValue;
  final bool done;

  /// The day is excused: it neither counts towards a streak nor breaks one.
  final bool skipped;
  final String note;

  /// Periods done in a row: due days, or a target's weeks, months or years.
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
    this.every = 1,
    required this.weekdays,
    required this.goal,
    required this.unit,
    required this.color,
    required this.categoryId,
    required this.due,
    required this.value,
    required this.periodValue,
    required this.done,
    required this.skipped,
    required this.note,
    required this.streak,
    required this.bestStreak,
    required this.weekValues,
    required this.weekSkipped,
  });

  factory TodayHabit.fromJson(Map<String, dynamic> json) => TodayHabit(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: HabitKind.values.byName(json['kind'] as String),
    schedule: Schedule.values.byName(json['schedule'] as String),
    every: json['every'] as int? ?? 1,
    weekdays: (json['weekdays'] as List?)?.cast<int>(),
    goal: json['goal'] as int,
    unit: json['unit'] as String? ?? '',
    color: json['color'] as String? ?? 'ink',
    categoryId: json['category_id'] as String?,
    due: json['due'] as bool,
    value: json['value'] as int,
    periodValue: json['period_value'] as int,
    done: json['done'] as bool,
    skipped: json['skipped'] as bool? ?? false,
    note: json['note'] as String? ?? '',
    streak: json['streak'] as int? ?? 0,
    bestStreak: json['best_streak'] as int? ?? 0,
    weekValues: (json['week_values'] as List?)?.cast<int>() ?? const [],
    weekSkipped: (json['week_skipped'] as List?)?.cast<bool>() ?? const [],
  );

  final String id;
  final String name;
  final HabitKind kind;
  final Schedule schedule;
  final int every;
  final List<int>? weekdays;
  final int goal;
  final String unit;
  final String color;
  final String? categoryId;
  final bool due;

  /// The day's own value.
  final int value;

  /// What completion is measured on: [value], or the period's sum for targets.
  final int periodValue;
  final bool done;

  /// The day is excused: it neither counts towards a streak nor breaks one.
  final bool skipped;
  final String note;

  /// Periods done in a row: due days, or a target's weeks, months or years.
  final int streak;
  final int bestStreak;

  /// The value of each day of the shown week, from its first day.
  final List<int> weekValues;
  final List<bool> weekSkipped;

  /// The row after a write. [dayIndex] is the shown day's place in the week.
  TodayHabit withStatus(EntryStatus status, int dayIndex) => TodayHabit(
    id: id,
    name: name,
    kind: kind,
    schedule: schedule,
    every: every,
    weekdays: weekdays,
    goal: goal,
    unit: unit,
    color: color,
    categoryId: categoryId,
    // As the server has it: a met target is only due on a day it was logged on.
    due: schedule.isTarget ? !status.done || status.value > 0 : due,
    value: status.value,
    periodValue: status.periodValue,
    done: status.done,
    skipped: status.skipped,
    note: status.note,
    streak: status.streak,
    bestStreak: status.bestStreak,
    weekValues: [
      for (var i = 0; i < weekValues.length; i++) i == dayIndex ? status.value : weekValues[i],
    ],
    weekSkipped: [
      for (var i = 0; i < weekSkipped.length; i++) i == dayIndex ? status.skipped : weekSkipped[i],
    ],
  );

  /// `3/8 pages`, `2/3 this month`, or nothing for a plain daily checkbox.
  String get progress {
    final amount = unit.isEmpty ? '' : ' $unit';
    if (schedule.isTarget) {
      return '$periodValue/$goal$amount this ${periodName(schedule, every)}';
    }
    if (kind == HabitKind.counter) return '$value/$goal$amount';
    return '';
  }
}

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.position,
    required this.collapsed,
  });

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: json['id'] as String,
    name: json['name'] as String,
    position: json['position'] as int,
    collapsed: json['collapsed'] as bool,
  );

  final String id;
  final String name;
  final int position;

  /// Folded away on Today and in the widget.
  final bool collapsed;

  Category withCollapsed(bool collapsed) =>
      Category(id: id, name: name, position: position, collapsed: collapsed);
}

/// One day of one habit, as `GET /entries` lists it.
class DayEntry {
  const DayEntry({this.value = 0, this.skipped = false, this.note = ''});

  factory DayEntry.fromJson(Map<String, dynamic> json) => DayEntry(
    value: json['value'] as int,
    skipped: json['skipped'] as bool? ?? false,
    note: json['note'] as String? ?? '',
  );

  final int value;
  final bool skipped;
  final String note;
}

class TodayView {
  const TodayView({
    required this.date,
    required this.weekStartDate,
    required this.categories,
    required this.habits,
  });

  factory TodayView.fromJson(Map<String, dynamic> json) => TodayView(
    date: json['date'] as String,
    weekStartDate: json['week_start_date'] as String,
    categories: ((json['categories'] as List?) ?? const [])
        .map((c) => Category.fromJson(c as Map<String, dynamic>))
        .toList(),
    habits: (json['habits'] as List)
        .map((h) => TodayHabit.fromJson(h as Map<String, dynamic>))
        .toList(),
  );

  final String date;
  final String weekStartDate;
  final List<Category> categories;
  final List<TodayHabit> habits;

  /// The shown day's place in its week, 0 to 6.
  int get dayIndex => parseYmd(date).difference(parseYmd(weekStartDate)).inDays;

  TodayView withStatus(EntryStatus status) => TodayView(
    date: date,
    weekStartDate: weekStartDate,
    categories: categories,
    habits: [
      for (final habit in habits)
        if (habit.id == status.habitId) habit.withStatus(status, dayIndex) else habit,
    ],
  );

  TodayView withCategory(Category changed) => TodayView(
    date: date,
    weekStartDate: weekStartDate,
    categories: [for (final c in categories) c.id == changed.id ? changed : c],
    habits: habits,
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
