package uk.pixxula.habytes

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// 2026-10-05 is a Monday.
internal val MONDAY: LocalDate = LocalDate.parse("2026-10-05")

internal fun habit(
    id: String,
    kind: Kind = Kind.BOOLEAN,
    schedule: Schedule = Schedule.DAILY,
    weekdays: List<Int>? = null,
    goal: Int = 1,
    value: Int = 0,
    periodValue: Int = value,
    streak: Int = 0,
) = Habit(id, "Habit $id", kind, schedule, weekdays, goal, value, periodValue, streak)

internal fun cache(vararg habits: Habit, date: LocalDate = MONDAY, weekStart: LocalDate = MONDAY) =
    Cache(date, weekStart, fetchedAt = 0, habits = habits.toList())

class ModelTest {
    @Test
    fun `an increment moves value and period value together`() {
        val daily = cache(habit("a", Kind.COUNTER, goal = 8, value = 3))
            .applying(Op.Increment("1", "a", MONDAY, 1)).habit("a")!!
        assertEquals(4, daily.value)
        assertEquals(4, daily.periodValue)

        val weekly = cache(habit("a", Kind.COUNTER, Schedule.WEEKLY, goal = 20, value = 3, periodValue = 12))
            .applying(Op.Increment("1", "a", MONDAY, 1)).habit("a")!!
        assertEquals(4, weekly.value)
        assertEquals(13, weekly.periodValue)
    }

    @Test
    fun `a set moves a weekly period by the difference`() {
        val start = cache(habit("a", schedule = Schedule.WEEKLY, goal = 3, value = 0, periodValue = 2))
        val checked = start.applying(Op.Set("1", "a", MONDAY, 1))
        assertEquals(3, checked.habit("a")!!.periodValue)
        assertTrue(checked.habit("a")!!.done)

        // Setting the same value again changes nothing.
        assertEquals(checked, checked.applying(Op.Set("2", "a", MONDAY, 1)))

        val unchecked = checked.applying(Op.Set("3", "a", MONDAY, 0))
        assertEquals(2, unchecked.habit("a")!!.periodValue)
        assertFalse(unchecked.habit("a")!!.done)
    }

    @Test
    fun `values are clamped like on the server`() {
        val boolean = cache(habit("a")).applying(Op.Set("1", "a", MONDAY, 5)).habit("a")!!
        assertEquals(1, boolean.value)

        val counter = cache(habit("a", Kind.COUNTER, value = 2))
        assertEquals(0, counter.applying(Op.Increment("1", "a", MONDAY, -5)).habit("a")!!.value)
        assertEquals(
            MAX_COUNTER_VALUE,
            counter.applying(Op.Set("1", "a", MONDAY, MAX_COUNTER_VALUE + 1)).habit("a")!!.value,
        )

        // A clamped weekly decrement only takes off what the day had.
        val weekly = cache(habit("a", Kind.COUNTER, Schedule.WEEKLY, goal = 20, value = 2, periodValue = 10))
            .applying(Op.Increment("1", "a", MONDAY, -5)).habit("a")!!
        assertEquals(8, weekly.periodValue)
    }

    @Test
    fun `an operation for an unknown habit is ignored`() {
        val start = cache(habit("a"))
        assertEquals(start, start.applying(Op.Increment("1", "gone", MONDAY, 1)))
    }

    @Test
    fun `an operation from an earlier day only counts towards the week`() {
        val tuesday = MONDAY.plusDays(1)
        val start = cache(
            habit("daily", Kind.COUNTER, goal = 8, value = 1),
            habit("weekly", Kind.COUNTER, Schedule.WEEKLY, goal = 20, value = 1, periodValue = 5),
            date = tuesday,
        )
        val after = start
            .applying(Op.Increment("1", "daily", MONDAY, 1))
            .applying(Op.Increment("2", "weekly", MONDAY, 1))
            // Last week's tap is not part of this week.
            .applying(Op.Increment("3", "weekly", MONDAY.minusDays(1), 1))
        assertEquals(1, after.habit("daily")!!.value)
        assertEquals(1, after.habit("weekly")!!.value)
        assertEquals(6, after.habit("weekly")!!.periodValue)
    }

    @Test
    fun `a new day in the same week keeps weekly totals`() {
        val start = cache(
            habit("daily", Kind.COUNTER, goal = 8, value = 8),
            habit("weekly", schedule = Schedule.WEEKLY, goal = 3, value = 1, periodValue = 2),
        )
        val sunday = start.rolledTo(MONDAY.plusDays(6))
        assertEquals(MONDAY.plusDays(6), sunday.date)
        assertEquals(MONDAY, sunday.weekStartDate)
        assertEquals(0, sunday.habit("daily")!!.value)
        assertEquals(0, sunday.habit("daily")!!.periodValue)
        assertFalse(sunday.habit("daily")!!.done)
        assertEquals(0, sunday.habit("weekly")!!.value)
        assertEquals(2, sunday.habit("weekly")!!.periodValue)

        assertEquals(start, start.rolledTo(MONDAY))
    }

    @Test
    fun `a new week resets weekly totals and moves the week start`() {
        val start = cache(habit("weekly", schedule = Schedule.WEEKLY, goal = 3, value = 1, periodValue = 3))
        val next = start.rolledTo(MONDAY.plusDays(7))
        assertEquals(MONDAY.plusDays(7), next.weekStartDate)
        assertEquals(0, next.habit("weekly")!!.periodValue)

        // Weeks need not start on Monday, and several may have passed.
        val saturday = MONDAY.minusDays(2)
        val later = cache(habit("weekly", schedule = Schedule.WEEKLY, periodValue = 1), weekStart = saturday)
            .rolledTo(MONDAY.plusDays(17))
        assertEquals(saturday.plusDays(14), later.weekStartDate)
        assertEquals(0, later.habit("weekly")!!.periodValue)

        // The clock can also go backwards, into the previous week.
        val earlier = start.rolledTo(MONDAY.minusDays(1))
        assertEquals(MONDAY.minusDays(7), earlier.weekStartDate)
        assertEquals(0, earlier.habit("weekly")!!.periodValue)
    }

    @Test
    fun `completing a habit extends its streak and undoing takes it back`() {
        val start = cache(
            habit("bool", streak = 4),
            habit("count", Kind.COUNTER, goal = 2, value = 1, streak = 6),
            habit("weekly", schedule = Schedule.WEEKLY, goal = 2, periodValue = 1, streak = 3),
        )
        val checked = start.applying(Op.Set("1", "bool", MONDAY, 1))
        assertEquals(5, checked.habit("bool")!!.streak)
        assertEquals(4, checked.applying(Op.Set("2", "bool", MONDAY, 0)).habit("bool")!!.streak)

        // Only reaching the goal counts, and going past it does not count twice.
        val reached = start.applying(Op.Increment("1", "count", MONDAY, 1))
        assertEquals(7, reached.habit("count")!!.streak)
        assertEquals(7, reached.applying(Op.Increment("2", "count", MONDAY, 1)).habit("count")!!.streak)

        assertEquals(4, start.applying(Op.Set("1", "weekly", MONDAY, 1)).habit("weekly")!!.streak)
    }

    @Test
    fun `a day that ended undone ends the streak`() {
        val start = cache(
            habit("done", value = 1, streak = 5),
            habit("missed", streak = 5),
            // Due on Monday and Wednesday only.
            habit("mon-wed", schedule = Schedule.WEEKDAYS, weekdays = listOf(1, 3), value = 1, streak = 5),
        )
        val tuesday = start.rolledTo(MONDAY.plusDays(1))
        assertEquals(5, tuesday.habit("done")!!.streak)
        assertEquals(0, tuesday.habit("missed")!!.streak)
        assertEquals(5, tuesday.habit("mon-wed")!!.streak)

        // Skipping a due day altogether ends it too; days off do not.
        val thursday = start.rolledTo(MONDAY.plusDays(3))
        assertEquals(0, thursday.habit("done")!!.streak)
        assertEquals(0, thursday.habit("mon-wed")!!.streak)
        assertEquals(5, start.rolledTo(MONDAY.plusDays(2)).habit("mon-wed")!!.streak)
    }

    @Test
    fun `a week that ended short ends a weekly streak`() {
        val start = cache(
            habit("met", schedule = Schedule.WEEKLY, goal = 2, periodValue = 2, streak = 3),
            habit("short", schedule = Schedule.WEEKLY, goal = 2, periodValue = 1, streak = 3),
        )
        // Within the week nothing changes.
        assertEquals(3, start.rolledTo(MONDAY.plusDays(6)).habit("short")!!.streak)
        val nextWeek = start.rolledTo(MONDAY.plusDays(7))
        assertEquals(3, nextWeek.habit("met")!!.streak)
        assertEquals(0, nextWeek.habit("short")!!.streak)
        // A whole week with nothing logged ends even a met one.
        assertEquals(0, start.rolledTo(MONDAY.plusDays(14)).habit("met")!!.streak)
    }

    @Test
    fun `only habits due on the cache date are listed`() {
        val start = cache(
            habit("daily"),
            habit("mon-wed", schedule = Schedule.WEEKDAYS, weekdays = listOf(1, 3)),
            habit("sunday", schedule = Schedule.WEEKDAYS, weekdays = listOf(7)),
            habit("weekly", schedule = Schedule.WEEKLY, goal = 1, periodValue = 1),
        )
        // A completed weekly habit stays in the list.
        assertEquals(listOf("daily", "mon-wed", "weekly"), start.dueHabits.map { it.id })
        assertEquals(listOf("daily", "weekly"), start.rolledTo(MONDAY.plusDays(1)).dueHabits.map { it.id })
        assertEquals(listOf("daily", "sunday", "weekly"), start.rolledTo(MONDAY.plusDays(6)).dueHabits.map { it.id })
    }

    @Test
    fun `progress text`() {
        assertEquals("", habit("a").progress)
        assertEquals("", habit("a", schedule = Schedule.WEEKDAYS, weekdays = listOf(1)).progress)
        assertEquals("3/8", habit("a", Kind.COUNTER, goal = 8, value = 3).progress)
        assertEquals("2/3 this week", habit("a", schedule = Schedule.WEEKLY, goal = 3, periodValue = 2).progress)
        assertEquals(
            "12/20 this week",
            habit("a", Kind.COUNTER, Schedule.WEEKLY, goal = 20, value = 1, periodValue = 12).progress,
        )
    }

    @Test
    fun `state survives a round trip through JSON`() {
        val start = cache(
            habit("a", Kind.COUNTER, Schedule.WEEKDAYS, weekdays = listOf(1, 5), goal = 8, value = 3, streak = 4),
            habit("b", schedule = Schedule.WEEKLY, goal = 3, value = 1, periodValue = 2),
        )
        assertEquals(start, cacheFromJson(start.toJson()))

        val outbox = listOf(Op.Increment("1", "a", MONDAY, 1), Op.Set("2", "b", MONDAY, 0))
        assertEquals(outbox, outboxFromJson(outbox.toJson()))
    }

    @Test
    fun `the today response is read`() {
        val body = """
            {"date":"2026-10-05","week_start_date":"2026-10-05","habits":[
              {"id":"a","name":"Drink water","kind":"counter","schedule":"weekdays","weekdays":[1,2,3],
               "goal":8,"due":true,"value":3,"period_value":3,"done":false,"streak":12,"best_streak":30},
              {"id":"b","name":"Gym","kind":"boolean","schedule":"weekly","weekdays":null,
               "goal":3,"due":true,"value":1,"period_value":2,"done":false}]}
        """
        val cache = cacheFromJson(body, fetchedAt = 42)
        assertEquals(MONDAY, cache.date)
        assertEquals(42, cache.fetchedAt)
        assertEquals(
            Habit("a", "Drink water", Kind.COUNTER, Schedule.WEEKDAYS, listOf(1, 2, 3), 8, 3, 3, 12),
            cache.habits[0],
        )
        // A server from before streaks sends none.
        assertEquals(Habit("b", "Gym", Kind.BOOLEAN, Schedule.WEEKLY, null, 3, 1, 2, 0), cache.habits[1])
    }
}
