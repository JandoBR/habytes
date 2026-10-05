//! Streaks: how many periods in a row a habit has been done.
//!
//! A period is a due day for `daily` and `weekdays` habits and a week for
//! `weekly` ones. Days a `weekdays` habit is not due neither count nor break
//! a streak. The period that is still running does not break one either: a
//! streak only ends once a period has passed without the habit being done.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{Days, NaiveDate};

use crate::schedule::{is_due, week_start_date};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Streaks {
    /// The run that includes, or ends right before, the current period.
    pub current: i64,
    /// The longest run ever, the current one included.
    pub best: i64,
}

/// What a streak is counted over.
pub struct Rules {
    pub weekly: bool,
    /// Bitmask of due days for a `weekdays` habit.
    pub weekdays: Option<i64>,
    pub goal: i64,
    /// The user's first day of the week, 1 = Monday ... 7 = Sunday.
    pub week_start: i64,
}

impl Rules {
    /// The start of the period before the one starting on `period`.
    fn previous(&self, period: NaiveDate) -> NaiveDate {
        if self.weekly {
            return period - Days::new(7);
        }
        let mut day = period - Days::new(1);
        while !is_due(self.weekdays, day) {
            day = day - Days::new(1);
        }
        day
    }

    /// The period `date` belongs to, or the last one before it if it is not a due day.
    fn period_of(&self, date: NaiveDate) -> NaiveDate {
        if self.weekly {
            week_start_date(date, self.week_start)
        } else if is_due(self.weekdays, date) {
            date
        } else {
            self.previous(date)
        }
    }
}

/// The streaks as of `as_of`, from one habit's values by day. Later entries are ignored.
pub fn streaks(rules: &Rules, entries: &BTreeMap<NaiveDate, i64>, as_of: NaiveDate) -> Streaks {
    // The periods in which the goal was met.
    let mut totals: BTreeMap<NaiveDate, i64> = BTreeMap::new();
    for (&date, &value) in entries.range(..=as_of) {
        if rules.weekly {
            *totals.entry(week_start_date(date, rules.week_start)).or_default() += value;
        } else if is_due(rules.weekdays, date) {
            totals.insert(date, value);
        }
    }
    let done: BTreeSet<NaiveDate> =
        totals.into_iter().filter(|&(_, total)| total >= rules.goal).map(|(p, _)| p).collect();

    let mut best = 0;
    let mut run = 0;
    let mut last: Option<NaiveDate> = None;
    for &period in &done {
        run = if last == Some(rules.previous(period)) { run + 1 } else { 1 };
        best = best.max(run);
        last = Some(period);
    }

    // The running period may still be completed, so it is skipped when open.
    let mut period = rules.period_of(as_of);
    if !done.contains(&period) {
        period = rules.previous(period);
    }
    let mut current = 0;
    while done.contains(&period) {
        current += 1;
        period = rules.previous(period);
    }

    Streaks { current, best }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schedule::{parse_date, weekdays_to_mask};

    // 2025-06-02 is a Monday.
    fn day(offset: u64) -> NaiveDate {
        parse_date("2025-06-02").unwrap() + Days::new(offset)
    }

    fn entries(days: &[(u64, i64)]) -> BTreeMap<NaiveDate, i64> {
        days.iter().map(|&(offset, value)| (day(offset), value)).collect()
    }

    fn daily(goal: i64) -> Rules {
        Rules { weekly: false, weekdays: None, goal, week_start: 1 }
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
            weekly: false,
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
        let rules = Rules { weekly: true, weekdays: None, goal: 3, week_start: 1 };
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
        let monday = Rules { weekly: true, weekdays: None, goal: 2, week_start: 1 };
        assert_eq!(streaks(&monday, &log, day(7)), Streaks { current: 2, best: 2 });
        // With weeks starting on Sunday both days fall in the same week.
        let sunday = Rules { weekly: true, weekdays: None, goal: 4, week_start: 7 };
        assert_eq!(streaks(&sunday, &log, day(7)), Streaks { current: 1, best: 1 });
    }
}
