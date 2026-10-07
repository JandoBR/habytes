//! Streaks: how many periods in a row a habit has been done.
//!
//! A period is a due day for `daily` and `weekdays` habits and the week, month,
//! year or several of them a target is set over for the others. Days a `weekdays` habit is not due neither count nor break
//! a streak, and neither does a period that was skipped (unless the habit was
//! done in it anyway). The period that is still running does not break one
//! either: a streak only ends once a period has passed without the habit
//! being done.

use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Bound::{Excluded, Included},
};

use chrono::{Days, NaiveDate};

use crate::schedule::{Period, is_due};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Streaks {
    /// The run that includes, or ends right before, the current period.
    pub current: i64,
    /// The longest run ever, the current one included.
    pub best: i64,
}

/// What a streak is counted over.
pub struct Rules {
    pub period: Period,
    /// Bitmask of due days for a `weekdays` habit.
    pub weekdays: Option<i64>,
    pub goal: i64,
    /// The user's first day of the week, 1 = Monday ... 7 = Sunday.
    pub week_start: i64,
}

impl Rules {
    /// The first day of the period `date` is in, which names the period.
    fn period_of(&self, date: NaiveDate) -> NaiveDate {
        self.period.start(date, self.week_start)
    }

    /// Whether `date` counts towards its period.
    fn counts(&self, date: NaiveDate) -> bool {
        self.period != Period::Day || is_due(self.weekdays, date)
    }
}

/// One habit's history, reduced to what streaks need.
struct Periods<'a> {
    rules: &'a Rules,
    /// The periods in which the goal was met.
    done: BTreeSet<NaiveDate>,
    /// The periods excused by a skipped day.
    skipped: BTreeSet<NaiveDate>,
}

impl Periods<'_> {
    /// Whether a period neither counts nor breaks a streak.
    fn off(&self, period: NaiveDate) -> bool {
        if self.done.contains(&period) {
            return false;
        }
        self.skipped.contains(&period) || !self.rules.counts(period)
    }

    fn step_back(&self, period: NaiveDate) -> NaiveDate {
        self.rules.period_of(period - Days::new(1))
    }

    /// The last period before `period` that counts.
    fn previous(&self, period: NaiveDate) -> NaiveDate {
        let mut previous = self.step_back(period);
        while self.off(previous) {
            previous = self.step_back(previous);
        }
        previous
    }

    /// The period `date` belongs to, or the last one before it that counts.
    fn period_of(&self, date: NaiveDate) -> NaiveDate {
        let period = self.rules.period_of(date);
        if self.off(period) { self.previous(period) } else { period }
    }
}

/// The streaks as of `as_of`, from one habit's values by day and the days
/// that were skipped. Later days are ignored.
pub fn streaks(
    rules: &Rules,
    entries: &BTreeMap<NaiveDate, i64>,
    skipped: &BTreeSet<NaiveDate>,
    as_of: NaiveDate,
) -> Streaks {
    let period = |date: NaiveDate| rules.period_of(date);
    let mut totals: BTreeMap<NaiveDate, i64> = BTreeMap::new();
    for (&date, &value) in entries.range(..=as_of) {
        if rules.counts(date) {
            *totals.entry(period(date)).or_default() += value;
        }
    }
    let periods = Periods {
        rules,
        done: totals
            .into_iter()
            .filter(|&(_, total)| total >= rules.goal)
            .map(|(p, _)| p)
            .collect(),
        skipped: skipped.range(..=as_of).map(|&date| period(date)).collect(),
    };

    let mut best = 0;
    let mut run = 0;
    let mut last: Option<NaiveDate> = None;
    for &period in &periods.done {
        run = if last == Some(periods.previous(period)) { run + 1 } else { 1 };
        best = best.max(run);
        last = Some(period);
    }

    // The running period may still be completed, so it is passed over when open.
    let mut period = periods.period_of(as_of);
    if !periods.done.contains(&period) {
        period = periods.previous(period);
    }
    let mut current = 0;
    while periods.done.contains(&period) {
        current += 1;
        period = periods.previous(period);
    }

    Streaks { current, best }
}

/// The streaks of an `interval` habit, which is due again `every` days after
/// it was last done: how many times in a row it was done by the day it came
/// due. Doing it early is fine, skipped days do not count as waiting, and the
/// streak stands until its due day has passed.
pub fn interval_streaks(
    every: i64,
    goal: i64,
    entries: &BTreeMap<NaiveDate, i64>,
    skipped: &BTreeSet<NaiveDate>,
    as_of: NaiveDate,
) -> Streaks {
    let waited = |from: NaiveDate, to: NaiveDate| {
        (to - from).num_days() - skipped.range((Excluded(from), Included(to))).count() as i64
    };
    let mut best = 0;
    let mut run = 0;
    let mut last: Option<NaiveDate> = None;
    for (&date, _) in entries.range(..=as_of).filter(|&(_, &value)| value >= goal) {
        run = if last.is_some_and(|last| waited(last, date) <= every) { run + 1 } else { 1 };
        best = best.max(run);
        last = Some(date);
    }
    let current = if last.is_some_and(|last| waited(last, as_of) <= every) { run } else { 0 };
    Streaks { current, best }
}

#[cfg(test)]
mod tests {
    use super::{Rules, Streaks};
    use std::collections::{BTreeMap, BTreeSet};

    use chrono::{Days, NaiveDate};

    use crate::schedule::{Period, parse_date, weekdays_to_mask};

    // 2025-06-02 is a Monday.
    fn day(offset: u64) -> NaiveDate {
        parse_date("2025-06-02").unwrap() + Days::new(offset)
    }

    fn entries(days: &[(u64, i64)]) -> BTreeMap<NaiveDate, i64> {
        days.iter().map(|&(offset, value)| (day(offset), value)).collect()
    }

    fn daily(goal: i64) -> Rules {
        Rules { period: Period::Day, weekdays: None, goal, week_start: 1 }
    }

    /// Streaks with no skipped days.
    fn streaks(rules: &Rules, log: &BTreeMap<NaiveDate, i64>, as_of: NaiveDate) -> Streaks {
        super::streaks(rules, log, &BTreeSet::new(), as_of)
    }

    fn skipping(offsets: &[u64]) -> BTreeSet<NaiveDate> {
        offsets.iter().map(|&offset| day(offset)).collect()
    }

    #[test]
    fn a_skipped_day_neither_counts_nor_breaks() {
        let log = entries(&[(0, 1), (1, 1), (3, 1)]);
        // Without the skip, the missed Wednesday ends the run.
        assert_eq!(streaks(&daily(1), &log, day(3)), Streaks { current: 1, best: 2 });
        let with_skip = super::streaks(&daily(1), &log, &skipping(&[2]), day(3));
        assert_eq!(with_skip, Streaks { current: 3, best: 3 });
        // A skipped day that is still running leaves the streak as it was.
        let today_skipped = super::streaks(&daily(1), &log, &skipping(&[2, 4]), day(4));
        assert_eq!(today_skipped, Streaks { current: 3, best: 3 });
        // Done on a skipped day still counts.
        let done_anyway = super::streaks(&daily(1), &log, &skipping(&[1, 2]), day(3));
        assert_eq!(done_anyway, Streaks { current: 3, best: 3 });
    }

    #[test]
    fn a_skipped_day_excuses_a_short_week() {
        let rules = Rules { period: Period::Weeks(1), weekdays: None, goal: 2, week_start: 1 };
        // Week 1 met, week 2 one day only, week 3 met.
        let log = entries(&[(0, 1), (1, 1), (7, 1), (14, 1), (15, 1)]);
        assert_eq!(streaks(&rules, &log, day(15)), Streaks { current: 1, best: 1 });
        let excused = super::streaks(&rules, &log, &skipping(&[9]), day(15));
        assert_eq!(excused, Streaks { current: 2, best: 2 });
    }

    #[test]
    fn nothing_logged_is_no_streak() {
        assert_eq!(streaks(&daily(1), &entries(&[]), day(3)), Streaks::default());
    }

    #[test]
    fn a_daily_streak_counts_back_from_today() {
        let log = entries(&[(0, 1), (1, 1), (2, 1)]);
        assert_eq!(streaks(&daily(1), &log, day(2)), Streaks { current: 3, best: 3 });
        // Today is still open: not being done yet does not break the streak.
        assert_eq!(streaks(&daily(1), &log, day(3)), Streaks { current: 3, best: 3 });
        // A whole day missed does.
        assert_eq!(streaks(&daily(1), &log, day(4)), Streaks { current: 0, best: 3 });
    }

    #[test]
    fn the_best_streak_outlives_the_current_one() {
        let log = entries(&[(0, 1), (1, 1), (2, 1), (3, 1), (5, 1), (6, 1)]);
        assert_eq!(streaks(&daily(1), &log, day(6)), Streaks { current: 2, best: 4 });
    }

    #[test]
    fn a_counter_day_counts_only_when_the_goal_is_met() {
        let log = entries(&[(0, 8), (1, 7), (2, 9), (3, 8)]);
        assert_eq!(streaks(&daily(8), &log, day(3)), Streaks { current: 2, best: 2 });
    }

    #[test]
    fn entries_after_the_date_are_ignored() {
        let log = entries(&[(0, 1), (1, 1), (2, 1)]);
        assert_eq!(streaks(&daily(1), &log, day(1)), Streaks { current: 2, best: 2 });
    }

    #[test]
    fn days_that_are_not_due_neither_count_nor_break() {
        // Due on Monday, Wednesday and Friday.
        let rules = Rules {
            period: Period::Day,
            weekdays: Some(weekdays_to_mask(&[1, 3, 5]).unwrap()),
            goal: 1,
            week_start: 1,
        };
        // Mon, Tue (not due), Wed, Fri, next Mon.
        let log = entries(&[(0, 1), (1, 1), (2, 1), (4, 1), (7, 1)]);
        assert_eq!(streaks(&rules, &log, day(7)), Streaks { current: 4, best: 4 });
        // On a day off the streak stands as it was.
        assert_eq!(streaks(&rules, &log, day(8)), Streaks { current: 4, best: 4 });
        // Wednesday is open, then missed.
        assert_eq!(streaks(&rules, &log, day(9)), Streaks { current: 4, best: 4 });
        assert_eq!(streaks(&rules, &log, day(11)), Streaks { current: 0, best: 4 });
    }

    #[test]
    fn a_weekly_streak_counts_weeks() {
        let rules = Rules { period: Period::Weeks(1), weekdays: None, goal: 3, week_start: 1 };
        // Week 1: three days. Week 2: three days. Week 3: two so far.
        let log = entries(&[(0, 1), (2, 1), (4, 1), (7, 1), (8, 1), (13, 1), (14, 1), (15, 1)]);
        assert_eq!(streaks(&rules, &log, day(15)), Streaks { current: 2, best: 2 });
        // Meeting the goal in the running week extends it at once.
        let mut met = log.clone();
        met.insert(day(16), 1);
        assert_eq!(streaks(&rules, &met, day(16)), Streaks { current: 3, best: 3 });
        // A week that ended short breaks it.
        assert_eq!(streaks(&rules, &log, day(21)), Streaks { current: 0, best: 2 });
    }

    #[test]
    fn weeks_follow_the_users_week_start() {
        // Sunday and Monday are in different weeks when weeks start on Monday.
        let log = entries(&[(6, 2), (7, 2)]);
        let monday = Rules { period: Period::Weeks(1), weekdays: None, goal: 2, week_start: 1 };
        assert_eq!(streaks(&monday, &log, day(7)), Streaks { current: 2, best: 2 });
        // With weeks starting on Sunday both days fall in the same week.
        let sunday = Rules { period: Period::Weeks(1), weekdays: None, goal: 4, week_start: 7 };
        assert_eq!(streaks(&sunday, &log, day(7)), Streaks { current: 1, best: 1 });
    }

    #[test]
    fn a_monthly_streak_counts_months() {
        let rules =
            Rules { period: Period::of("monthly", 1), weekdays: None, goal: 2, week_start: 1 };
        let on = |date: &str| parse_date(date).unwrap();
        let log: BTreeMap<NaiveDate, i64> = [
            ("2025-03-03", 1),
            ("2025-03-30", 1),
            ("2025-04-01", 2),
            ("2025-05-31", 1),
            ("2025-06-10", 1),
        ]
        .into_iter()
        .map(|(date, value)| (on(date), value))
        .collect();
        // March and April met; May is still running.
        assert_eq!(streaks(&rules, &log, on("2025-05-31")), Streaks { current: 2, best: 2 });
        // May ended one short.
        assert_eq!(streaks(&rules, &log, on("2025-06-30")), Streaks { current: 0, best: 2 });
        // Over quarters the same days add up to two met in a row.
        let quarterly = Rules { period: Period::of("monthly", 3), ..rules };
        assert_eq!(streaks(&quarterly, &log, on("2025-06-30")), Streaks { current: 2, best: 2 });
    }

    #[test]
    fn an_interval_streak_counts_times_done_before_they_were_due() {
        let streaks = |log: &BTreeMap<NaiveDate, i64>, skipped: &[u64], as_of: u64| {
            super::interval_streaks(3, 1, log, &skipping(skipped), day(as_of))
        };
        // Every three days: on time, a day early, then two days late.
        let log = entries(&[(0, 1), (3, 1), (5, 1), (10, 1)]);
        assert_eq!(streaks(&log, &[], 5), Streaks { current: 3, best: 3 });
        // It stands through the day it is due, and ends once that has passed.
        assert_eq!(streaks(&log, &[], 8), Streaks { current: 3, best: 3 });
        assert_eq!(streaks(&log, &[], 9), Streaks { current: 0, best: 3 });
        assert_eq!(streaks(&log, &[], 10), Streaks { current: 1, best: 3 });
        // Skipped days are not waited through.
        assert_eq!(streaks(&log, &[8, 9], 10), Streaks { current: 4, best: 4 });
        assert_eq!(streaks(&entries(&[]), &[], 3), Streaks::default());
    }
}
