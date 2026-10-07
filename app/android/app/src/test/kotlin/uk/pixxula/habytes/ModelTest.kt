package uk.pixxula.habytes

import java.time.LocalDate
import java.time.LocalTime
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
    every: Int = 1,
    // A target's running period: the week of MONDAY unless the test says otherwise.
    period: Period? = if (schedule.isTarget) Period(MONDAY, MONDAY.plusDays(6)) else null,
) = Habit(id, "Habit $id", kind, schedule, weekdays, goal, value, periodValue, streak, every = every, period = period)

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
    fun `a month keeps its total until it ends`() {
        val october = Period(LocalDate.parse("2026-10-01"), LocalDate.parse("2026-10-31"))
        val start = cache(
            habit("met", schedule = Schedule.MONTHLY, goal = 2, value = 1, periodValue = 2, streak = 3, period = october),
            habit("short", schedule = Schedule.MONTHLY, goal = 2, periodValue = 1, streak = 3, period = october),
        )
        val lastDay = start.rolledTo(october.end)
        assertEquals(0, lastDay.habit("met")!!.value)
        assertEquals(2, lastDay.habit("met")!!.periodValue)
        assertEquals(3, lastDay.habit("short")!!.streak)

        val november = start.rolledTo(LocalDate.parse("2026-11-01"))
        assertEquals(0, november.habit("met")!!.periodValue)
        assertEquals(3, november.habit("met")!!.streak)
        assertEquals(0, november.habit("short")!!.streak)
        assertEquals(
            Period(LocalDate.parse("2026-11-01"), LocalDate.parse("2026-11-30")),
            november.habit("met")!!.period,
        )
        // A whole month with nothing logged ends even a met one.
        val december = start.rolledTo(LocalDate.parse("2026-12-15"))
        assertEquals(0, december.habit("met")!!.streak)
        assertEquals(LocalDate.parse("2026-12-31"), december.habit("met")!!.period!!.end)
    }

    @Test
    fun `longer periods move on in whole blocks`() {
        val quarter = Period(LocalDate.parse("2026-10-01"), LocalDate.parse("2026-12-31"))
        val year = Period(LocalDate.parse("2026-01-01"), LocalDate.parse("2026-12-31"))
        val fortnight = Period(MONDAY.minusDays(7), MONDAY.plusDays(6))
        val start = cache(
            habit("quarter", schedule = Schedule.MONTHLY, goal = 1, periodValue = 1, every = 3, period = quarter),
            habit("year", Kind.COUNTER, Schedule.YEARLY, goal = 5, periodValue = 4, period = year),
            habit("fortnight", schedule = Schedule.WEEKLY, goal = 3, periodValue = 2, every = 2, period = fortnight),
        )
        val december = start.rolledTo(LocalDate.parse("2026-12-31"))
        assertEquals(1, december.habit("quarter")!!.periodValue)
        assertEquals(4, december.habit("year")!!.periodValue)
        assertEquals(0, december.habit("fortnight")!!.periodValue)

        val january = start.rolledTo(LocalDate.parse("2027-01-01"))
        assertEquals(0, january.habit("quarter")!!.periodValue)
        assertEquals(Period(LocalDate.parse("2027-01-01"), LocalDate.parse("2027-03-31")), january.habit("quarter")!!.period)
        assertEquals(Period(LocalDate.parse("2027-01-01"), LocalDate.parse("2027-12-31")), january.habit("year")!!.period)

        // The second week of the fortnight still counts; the week after does not.
        assertEquals(2, start.rolledTo(MONDAY.plusDays(6)).habit("fortnight")!!.periodValue)
        val next = start.rolledTo(MONDAY.plusDays(7)).habit("fortnight")!!
        assertEquals(0, next.periodValue)
        assertEquals(Period(MONDAY.plusDays(7), MONDAY.plusDays(20)), next.period)

        // An unsent tap from earlier in the year still counts towards it.
        val tapped = start.applying(Op.Increment("1", "year", LocalDate.parse("2026-02-01"), 1)).habit("year")!!
        assertEquals(0, tapped.value)
        assertEquals(5, tapped.periodValue)
    }

    @Test
    fun `a skipped day does not end the streak, and is not skipped tomorrow`() {
        val start = cache(habit("a", streak = 5).copy(skipped = true))
        assertTrue(start.habit("a")!!.excused)
        assertTrue(start.countedHabits.isEmpty())
        val tuesday = start.rolledTo(MONDAY.plusDays(1))
        assertEquals(5, tuesday.habit("a")!!.streak)
        assertFalse(tuesday.habit("a")!!.skipped)
        // Done on a skipped day is simply done.
        val done = start.applying(Op.Set("1", "a", MONDAY, 1)).habit("a")!!
        assertFalse(done.excused)
        assertEquals(6, done.streak)
    }

    @Test
    fun `habits are listed under their categories, hidden when folded`() {
        val health = Category("h", "Health", collapsed = false)
        val mind = Category("m", "Mind", collapsed = true)
        val empty = Category("e", "Empty", collapsed = false)
        val start = cache(
            habit("water").copy(categoryId = "h"),
            habit("loose"),
            habit("read").copy(categoryId = "m"),
            habit("gone").copy(categoryId = "deleted"),
            habit("off", schedule = Schedule.WEEKDAYS, weekdays = listOf(7)).copy(categoryId = "e"),
        ).copy(categories = listOf(health, mind, empty))

        val sections = start.sections
        // Uncategorised first; a category with nothing due today is left out.
        assertEquals(listOf(null, health, mind), sections.map { it.category })
        assertEquals(listOf("loose", "gone"), sections[0].visible.map { it.id })
        assertEquals(listOf("water"), sections[1].visible.map { it.id })
        // A folded category keeps its heading and count but shows no habits.
        assertTrue(sections[2].visible.isEmpty())
        assertEquals(listOf("read"), sections[2].habits.map { it.id })
    }

    @Test
    fun `a reminder is for a due habit that is neither done nor skipped`() {
        assertTrue(habit("a").needsReminder(MONDAY))
        assertFalse(habit("a", value = 1).needsReminder(MONDAY))
        assertFalse(habit("a").copy(skipped = true).needsReminder(MONDAY))
        assertFalse(habit("a", schedule = Schedule.WEEKDAYS, weekdays = listOf(2)).needsReminder(MONDAY))
        // A target is reminded until its period's goal is met.
        val weekly = habit("a", schedule = Schedule.WEEKLY, goal = 2, value = 1, periodValue = 1)
        assertTrue(weekly.needsReminder(MONDAY))
        assertFalse(weekly.copy(periodValue = 2).needsReminder(MONDAY))
    }

    @Test
    fun `the next reminder is today if still ahead, otherwise tomorrow`() {
        val daily = Reminder(LocalTime.of(20, 30))
        assertEquals(MONDAY.atTime(20, 30), daily.next(MONDAY.atTime(9, 0)))
        assertEquals(MONDAY.plusDays(1).atTime(20, 30), daily.next(MONDAY.atTime(20, 30)))
        assertEquals(MONDAY.plusDays(1).atTime(20, 30), daily.next(MONDAY.atTime(23, 0)))
    }

    @Test
    fun `a reminder limited to some days waits for the next of them`() {
        // Mondays and Thursdays.
        val reminder = Reminder(LocalTime.of(7, 0), days = listOf(1, 4))
        assertTrue(reminder.appliesOn(MONDAY))
        assertFalse(reminder.appliesOn(MONDAY.plusDays(1)))
        assertEquals(MONDAY.atTime(7, 0), reminder.next(MONDAY.atTime(6, 0)))
        assertEquals(MONDAY.plusDays(3).atTime(7, 0), reminder.next(MONDAY.atTime(8, 0)))
        assertEquals(MONDAY.plusDays(7).atTime(7, 0), reminder.next(MONDAY.plusDays(3).atTime(7, 0)))
    }

    @Test
    fun `only habits due on the cache date are listed`() {
        val start = cache(
            habit("daily"),
            habit("mon-wed", schedule = Schedule.WEEKDAYS, weekdays = listOf(1, 3)),
            habit("sunday", schedule = Schedule.WEEKDAYS, weekdays = listOf(7)),
            habit("weekly", schedule = Schedule.WEEKLY, goal = 1, value = 1, periodValue = 1),
            habit("open", schedule = Schedule.WEEKLY, goal = 2, periodValue = 1),
        )
        // A target met today stays for the day, then is out of the list until its next period.
        assertEquals(listOf("daily", "mon-wed", "weekly", "open"), start.dueHabits.map { it.id })
        assertEquals(listOf("daily", "open"), start.rolledTo(MONDAY.plusDays(1)).dueHabits.map { it.id })
        assertEquals(listOf("daily", "sunday", "open"), start.rolledTo(MONDAY.plusDays(6)).dueHabits.map { it.id })
        assertEquals(
            listOf("daily", "mon-wed", "weekly", "open"),
            start.rolledTo(MONDAY.plusDays(7)).dueHabits.map { it.id },
        )
    }

    @Test
    fun `targets over more than a week are listed but not counted in the day`() {
        val start = cache(
            habit("daily"),
            habit("weekly", schedule = Schedule.WEEKLY, goal = 2),
            habit("fortnight", schedule = Schedule.WEEKLY, goal = 2, every = 2),
            habit("monthly", schedule = Schedule.MONTHLY, goal = 2),
            habit("yearly", schedule = Schedule.YEARLY, goal = 2),
            habit("skipped").copy(skipped = true),
        )
        assertEquals(6, start.dueHabits.size)
        assertEquals(listOf("daily", "weekly"), start.countedHabits.map { it.id })
    }

    @Test
    fun `an interval habit rests after it is done and comes due again`() {
        val start = cache(habit("plants", schedule = Schedule.INTERVAL, every = 3, streak = 2))
        assertEquals(listOf("plants"), start.dueHabits.map { it.id })
        // Left undone on a day it was due, its streak ends and it stays due.
        val missed = start.rolledTo(MONDAY.plusDays(1)).habit("plants")!!
        assertEquals(0, missed.streak)
        assertTrue(missed.isDueOn(MONDAY.plusDays(1)))

        val done = start.applying(Op.Set("1", "plants", MONDAY, 1))
        assertEquals(3, done.habit("plants")!!.streak)
        assertEquals(listOf("plants"), done.dueHabits.map { it.id })
        // It rests for two days, keeping its streak, and is due on the third.
        val tuesday = done.rolledTo(MONDAY.plusDays(1))
        assertTrue(tuesday.dueHabits.isEmpty())
        // Done early all the same, it is part of that day.
        val early = tuesday.applying(Op.Set("2", "plants", MONDAY.plusDays(1), 1))
        assertEquals(listOf("plants"), early.dueHabits.map { it.id })
        assertFalse(tuesday.habit("plants")!!.needsReminder(MONDAY.plusDays(1)))
        assertEquals(3, tuesday.habit("plants")!!.streak)
        val thursday = tuesday.rolledTo(MONDAY.plusDays(3))
        assertEquals(listOf("plants"), thursday.dueHabits.map { it.id })
        assertEquals(3, thursday.habit("plants")!!.streak)
        assertEquals(0, thursday.rolledTo(MONDAY.plusDays(4)).habit("plants")!!.streak)
        assertEquals(thursday, cacheFromJson(thursday.toJson()))
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
        assertEquals("1/2 this month", habit("a", schedule = Schedule.MONTHLY, goal = 2, periodValue = 1).progress)
        assertEquals("1/4 this year", habit("a", schedule = Schedule.YEARLY, goal = 4, periodValue = 1).progress)
        assertEquals("0/1 this quarter", habit("a", schedule = Schedule.MONTHLY, every = 3).progress)
        assertEquals("0/1 this period", habit("a", schedule = Schedule.WEEKLY, every = 2).progress)
        assertEquals("3 months", habit("a", schedule = Schedule.MONTHLY, streak = 3).streakText)
        assertEquals("2 periods", habit("a", schedule = Schedule.YEARLY, every = 2, streak = 2).streakText)
    }

    @Test
    fun `state survives a round trip through JSON`() {
        val start = cache(
            habit("a", Kind.COUNTER, Schedule.WEEKDAYS, weekdays = listOf(1, 5), goal = 8, value = 3, streak = 4),
            habit("c", schedule = Schedule.YEARLY, goal = 3, every = 2),
            habit("b", schedule = Schedule.WEEKLY, goal = 3, value = 1, periodValue = 2)
                .copy(
                    unit = "km",
                    skipped = true,
                    categoryId = "c",
                    reminders = listOf(Reminder(LocalTime.of(7, 5), listOf(2, 3)), Reminder(LocalTime.NOON)),
                ),
        ).copy(categories = listOf(Category("c", "Health", collapsed = true)))
        assertEquals(start, cacheFromJson(start.toJson()))

        val outbox = listOf(Op.Increment("1", "a", MONDAY, 1), Op.Set("2", "b", MONDAY, 0))
        assertEquals(outbox, outboxFromJson(outbox.toJson()))
    }

    @Test
    fun `the today response is read`() {
        val body = """
            {"date":"2026-10-05","week_start_date":"2026-10-05",
             "categories":[{"id":"c1","name":"Health","position":0,"collapsed":true}],"habits":[
              {"id":"a","name":"Drink water","kind":"counter","schedule":"weekdays","weekdays":[1,2,3],
               "goal":8,"due":true,"value":3,"period_value":3,"done":false,"streak":12,"best_streak":30,
               "unit":"glasses","skipped":true,"category_id":"c1",
               "reminders":[{"time":"21:30","days":null},{"time":"07:00","days":[1,5]}]},
              {"id":"b","name":"Gym","kind":"boolean","schedule":"weekly","weekdays":null,
               "goal":3,"due":true,"value":1,"period_value":2,"done":false},
              {"id":"c","name":"Dentist","kind":"boolean","schedule":"monthly","every":3,"weekdays":null,
               "goal":1,"due":true,"value":0,"period_value":0,"done":false,
               "period_start":"2026-10-01","period_end":"2026-12-31"}]}
        """
        val cache = cacheFromJson(body, fetchedAt = 42)
        assertEquals(MONDAY, cache.date)
        assertEquals(42, cache.fetchedAt)
        assertEquals(
            Habit(
                "a", "Drink water", Kind.COUNTER, Schedule.WEEKDAYS, listOf(1, 2, 3), 8, 3, 3, 12,
                unit = "glasses", skipped = true, categoryId = "c1",
                reminders = listOf(
                    Reminder(LocalTime.of(21, 30)),
                    Reminder(LocalTime.of(7, 0), listOf(1, 5)),
                ),
            ),
            cache.habits[0],
        )
        assertEquals("3/8 glasses", cache.habits[0].progress)
        assertEquals(listOf(Category("c1", "Health", true)), cache.categories)
        // A server from before streaks and periods sends neither: the period is the week.
        assertEquals(
            Habit("b", "Gym", Kind.BOOLEAN, Schedule.WEEKLY, null, 3, 1, 2, 0, period = Period(MONDAY, MONDAY.plusDays(6))),
            cache.habits[1],
        )
        assertEquals(3, cache.habits[2].every)
        assertEquals(Period(LocalDate.parse("2026-10-01"), LocalDate.parse("2026-12-31")), cache.habits[2].period)
    }
}
