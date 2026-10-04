package uk.pixxula.habytes

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/** The widget's state: today's cache and the outbox of unsent taps. No Android in here. */

enum class Kind { BOOLEAN, COUNTER }

enum class Schedule { DAILY, WEEKDAYS, WEEKLY }

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
    /** What completion is measured on: [value], or the week's sum for weekly habits. */
    val periodValue: Int,
) {
    val done: Boolean get() = periodValue >= goal

    val checkedToday: Boolean get() = value > 0

    fun isDueOn(date: LocalDate): Boolean = weekdays?.contains(date.dayOfWeek.value) ?: true

    /** `3/8`, `2/3 this week`, or nothing for a plain daily checkbox. */
    val progress: String
        get() = when {
            schedule == Schedule.WEEKLY -> "$periodValue/$goal this week"
            kind == Kind.COUNTER -> "$value/$goal"
            else -> ""
        }

    private val maxValue: Int get() = if (kind == Kind.BOOLEAN) 1 else MAX_COUNTER_VALUE

    /** This habit with the day's value set, and the period's value moved along with it. */
    fun withValue(newValue: Int): Habit {
        val clamped = newValue.coerceIn(0, maxValue)
        val period = if (schedule == Schedule.WEEKLY) periodValue + (clamped - value) else clamped
        return copy(value = clamped, periodValue = period.coerceAtLeast(0))
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
) {
    /** The habits the widget lists: those due on the cache's date. */
    val dueHabits: List<Habit> get() = habits.filter { it.isDueOn(date) }

    fun habit(id: String): Habit? = habits.firstOrNull { it.id == id }

    private fun inWeek(day: LocalDate): Boolean =
        ChronoUnit.DAYS.between(weekStartDate, day) in 0..6

    /**
     * The cache as it should look on [today], without asking the server:
     * a new day starts every value at 0, and a new week starts weekly totals at 0.
     */
    fun rolledTo(today: LocalDate): Cache {
        if (today == date) return this
        val sameWeek = inWeek(today)
        val weeks = Math.floorDiv(ChronoUnit.DAYS.between(weekStartDate, today), 7L)
        return copy(
            date = today,
            weekStartDate = weekStartDate.plusDays(weeks * 7),
            habits = habits.map {
                val keepPeriod = sameWeek && it.schedule == Schedule.WEEKLY
                it.copy(value = 0, periodValue = if (keepPeriod) it.periodValue else 0)
            },
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
            // An unsent tap from an earlier day of this week still counts towards
            // the week. (An unsent "set" does too, but by an amount only the
            // server knows; the next refresh brings it.)
            op is Op.Increment && habit.schedule == Schedule.WEEKLY && inWeek(op.date) ->
                habit.copy(periodValue = (habit.periodValue + op.delta).coerceAtLeast(0))
            else -> habit
        }
        return copy(habits = habits.map { if (it.id == habit.id) updated else it })
    }
}

data class Credentials(val serverUrl: String, val token: String)
