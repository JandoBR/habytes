package uk.pixxula.habytes

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.temporal.ChronoUnit

/** The widget's state: today's cache and the outbox of unsent taps. No Android in here. */

enum class Kind { BOOLEAN, COUNTER }

enum class Schedule {
    DAILY,
    WEEKDAYS,
    WEEKLY,
    MONTHLY,
    YEARLY,

    /** Due again some days after it was last done. */
    INTERVAL;

    /** Whether the goal is for a whole period rather than for each day. */
    val isTarget: Boolean get() = this == WEEKLY || this == MONTHLY || this == YEARLY
}

/** The first and last day of the stretch a target's goal is measured over. */
data class Period(val start: LocalDate, val end: LocalDate) {
    operator fun contains(day: LocalDate): Boolean = !day.isBefore(start) && !day.isAfter(end)
}

const val MAX_COUNTER_VALUE = 1_000_000

data class Habit(
    val id: String,
    val name: String,
    val kind: Kind,
    val schedule: Schedule,
    /** Day numbers, 1 = Monday ... 7 = Sunday. Only for [Schedule.WEEKDAYS]. */
    val weekdays: List<Int>?,
    val goal: Int,
    /** The day's own value. */
    val value: Int,
    /** What completion is measured on: [value], or the period's sum for targets. */
    val periodValue: Int,
    /** Periods done in a row: due days, or a target's weeks, months or years. */
    val streak: Int = 0,
    /** What a counter counts: `pages`, `ml`. May be empty. */
    val unit: String = "",
    /** Today is excused: it neither counts towards the streak nor breaks it. */
    val skipped: Boolean = false,
    val categoryId: String? = null,
    /** When to remind about it if it is not done yet. */
    val reminders: List<Reminder> = emptyList(),
    /** How many weeks, months or years a target's period spans, or the days of an interval; 1 otherwise. */
    val every: Int = 1,
    /** The running period of a target. */
    val period: Period? = null,
    /** The day an interval habit comes due again after it was last done, before today. */
    val dueFrom: LocalDate? = null,
) {
    val done: Boolean get() = periodValue >= goal

    val checkedToday: Boolean get() = value > 0

    /**
     * Whether it belongs in [date]'s list: on one of its weekdays, once an
     * interval has run out, and for a target until it is met. A resting
     * interval or a met target stays on a day it was logged on.
     */
    fun isDueOn(date: LocalDate): Boolean = when {
        schedule.isTarget -> !done || checkedToday
        dueFrom != null -> checkedToday || !date.isBefore(dueFrom)
        else -> weekdays?.contains(date.dayOfWeek.value) ?: true
    }

    /** `week`, `quarter`, `period`: what one period of the schedule is called. */
    private val periodName: String
        get() = when {
            schedule == Schedule.INTERVAL -> "time"
            schedule == Schedule.MONTHLY && every == 3 -> "quarter"
            every != 1 -> "period"
            schedule == Schedule.WEEKLY -> "week"
            schedule == Schedule.MONTHLY -> "month"
            schedule == Schedule.YEARLY -> "year"
            else -> "day"
        }

    /** `12 days`, `3 weeks`, `4 times`; nothing for a streak too short to mention. */
    val streakText: String get() = if (streak < 2) "" else "$streak ${periodName}s"

    /** `3/8 pages`, `2/3 this month`, or nothing for a plain daily checkbox. */
    val progress: String
        get() {
            val amount = if (unit.isEmpty()) "" else " $unit"
            return when {
                schedule.isTarget -> "$periodValue/$goal$amount this $periodName"
                kind == Kind.COUNTER -> "$value/$goal$amount"
                else -> ""
            }
        }

    /** Skipped today, and not done all the same. */
    val excused: Boolean get() = skipped && !done

    /**
     * Whether it counts in the day's "done" tally: not when excused, and not a
     * target over more than a week, which would hold every day back until its
     * period was met.
     */
    val inTally: Boolean
        get() = !excused && (!schedule.isTarget || (schedule == Schedule.WEEKLY && every == 1))

    /** Whether a reminder for this habit is still called for on [date]. */
    fun needsReminder(date: LocalDate): Boolean = isDueOn(date) && !done && !skipped

    private val maxValue: Int get() = if (kind == Kind.BOOLEAN) 1 else MAX_COUNTER_VALUE

    /** This habit with the day's value set, and the period's value moved along with it. */
    fun withValue(newValue: Int): Habit {
        val clamped = newValue.coerceIn(0, maxValue)
        val total = if (schedule.isTarget) periodValue + (clamped - value) else clamped
        val changed = copy(value = clamped, periodValue = total.coerceAtLeast(0))
        // Completing the running period extends the streak; undoing it takes that back.
        val streak = when {
            changed.done && !done -> streak + 1
            !changed.done && done -> (streak - 1).coerceAtLeast(0)
            else -> streak
        }
        return changed.copy(streak = streak)
    }

    /** The period [day] is in, worked out from the running one, and how many periods on that is. */
    private fun periodOn(day: LocalDate): Pair<Period, Long>? {
        val (start, end) = period ?: return null
        if (schedule == Schedule.WEEKLY) {
            // Weeks, or blocks of them, are all as long as the running one.
            val length = ChronoUnit.DAYS.between(start, end) + 1
            val steps = Math.floorDiv(ChronoUnit.DAYS.between(start, day), length)
            return Period(start.plusDays(steps * length), end.plusDays(steps * length)) to steps
        }
        // Months and years start on the first of a month.
        val length = (if (schedule == Schedule.YEARLY) 12L else 1L) * every
        val months = ChronoUnit.MONTHS.between(start, day.withDayOfMonth(1))
        val steps = Math.floorDiv(months, length)
        val moved = start.plusMonths(steps * length)
        return Period(moved, moved.plusMonths(length).minusDays(1)) to steps
    }

    /**
     * This habit on [to], having last been looked at on [from]: a new day
     * starts its value at 0, a new period starts a target's total at 0, and
     * a period that ended without the habit done ends its streak.
     */
    internal fun rolled(from: LocalDate, to: LocalDate): Habit {
        if (schedule == Schedule.INTERVAL) {
            // Done on the day it was last looked at, it rests from then.
            val rested = if (done && to.isAfter(from)) copy(dueFrom = from.plusDays(every.toLong())) else this
            return rested.copy(value = 0, skipped = false, periodValue = 0, streak = rested.dailyStreakAfter(from, to))
        }
        val day = copy(value = 0, skipped = false)
        if (!schedule.isTarget) return day.copy(periodValue = 0, streak = dailyStreakAfter(from, to))
        val (next, steps) = periodOn(to) ?: return day.copy(periodValue = 0, streak = 0)
        return when {
            steps == 0L -> day
            // The period that just ended counts only if its goal was met
            // (or it was excused by a skipped day, as far as this cache knows).
            steps == 1L && (done || skipped) -> day.copy(periodValue = 0, period = next)
            else -> day.copy(periodValue = 0, period = next, streak = 0)
        }
    }

    /** The streak of a habit with a goal per day once the days from [from] up to, but not including, [to] are over. */
    private fun dailyStreakAfter(from: LocalDate, to: LocalDate): Int {
        if (!to.isAfter(from)) return streak
        if (isDueOn(from) && !done && !skipped) return 0
        // Any due day skipped entirely in between also ends it.
        var day = from.plusDays(1)
        while (day.isBefore(to)) {
            if (isDueOn(day)) return 0
            day = day.plusDays(1)
        }
        return streak
    }
}

sealed interface Op {
    val opId: String
    val habitId: String

    /** The local date at the moment of the tap. */
    val date: LocalDate

    data class Increment(
        override val opId: String,
        override val habitId: String,
        override val date: LocalDate,
        val delta: Int,
    ) : Op

    data class Set(
        override val opId: String,
        override val habitId: String,
        override val date: LocalDate,
        val value: Int,
    ) : Op
}

data class Cache(
    val date: LocalDate,
    val weekStartDate: LocalDate,
    /** Unix seconds. */
    val fetchedAt: Long,
    /** Every non-archived habit in order, due today or not. */
    val habits: List<Habit>,
    val categories: List<Category> = emptyList(),
) {
    /** The habits due on the cache's date. */
    val dueHabits: List<Habit> get() = habits.filter { it.isDueOn(date) }

    /** The due habits that are part of the day's tally. */
    val countedHabits: List<Habit> get() = dueHabits.filter { it.inTally }

    /**
     * What the widget lists, top to bottom: the due habits without a category,
     * then each category that has due habits, with them under it unless it is
     * folded.
     */
    val sections: List<Section>
        get() {
            val due = dueHabits
            val known = categories.map { it.id }.toSet()
            val loose = due.filter { it.categoryId !in known }
            return listOfNotNull(Section(null, loose).takeIf { loose.isNotEmpty() }) +
                categories.mapNotNull { category ->
                    val habits = due.filter { it.categoryId == category.id }
                    Section(category, habits).takeIf { habits.isNotEmpty() }
                }
        }

    fun habit(id: String): Habit? = habits.firstOrNull { it.id == id }

    /**
     * The cache as it should look on [today], without asking the server:
     * a new day starts every value at 0, a new period starts a target's total
     * at 0, and a period that ended without the habit done ends its streak.
     */
    fun rolledTo(today: LocalDate): Cache {
        if (today == date) return this
        val weeks = Math.floorDiv(ChronoUnit.DAYS.between(weekStartDate, today), 7L)
        return copy(
            date = today,
            weekStartDate = weekStartDate.plusDays(weeks * 7),
            habits = habits.map { it.rolled(date, today) },
        )
    }

    /** The cache with [op] applied on top, as the server will apply it. */
    fun applying(op: Op): Cache {
        val habit = habit(op.habitId) ?: return this
        val updated = when {
            op.date == date -> when (op) {
                is Op.Increment -> habit.withValue(habit.value + op.delta)
                is Op.Set -> habit.withValue(op.value)
            }
            // An unsent tap from an earlier day of the running period still counts
            // towards it. (An unsent "set" does too, but by an amount only the
            // server knows; the next refresh brings it.)
            op is Op.Increment && habit.period?.contains(op.date) == true ->
                habit.copy(periodValue = (habit.periodValue + op.delta).coerceAtLeast(0))
            else -> habit
        }
        return copy(habits = habits.map { if (it.id == habit.id) updated else it })
    }
}

data class Category(val id: String, val name: String, val collapsed: Boolean)

/** A run of habits in the widget, under a [category] heading or under none. */
data class Section(val category: Category?, val habits: List<Habit>) {
    /** The habits shown: none while the category is folded. */
    val visible: List<Habit> get() = if (category?.collapsed == true) emptyList() else habits
}

/**
 * A local time of day to remind about a habit, on every day or only on some
 * weekdays ([days], 1 = Monday ... 7 = Sunday; null for every day).
 */
data class Reminder(val time: LocalTime, val days: List<Int>? = null) {
    fun appliesOn(date: LocalDate): Boolean = days?.contains(date.dayOfWeek.value) ?: true

    /** The next moment it should go off, strictly after [now]. */
    fun next(now: LocalDateTime): LocalDateTime {
        var day = now.toLocalDate()
        // Today if the time is still ahead, otherwise the next day it applies on.
        repeat(8) {
            val at = day.atTime(time)
            if (appliesOn(day) && at.isAfter(now)) return at
            day = day.plusDays(1)
        }
        // Unreachable for a reminder with at least one day.
        return now.plusDays(7)
    }
}

data class Credentials(val serverUrl: String, val token: String)
