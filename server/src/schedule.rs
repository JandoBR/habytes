//! Schedules and completion (spec section 4). Everything here works on
//! calendar dates, so no time zone is involved.

use chrono::{Datelike, Days, NaiveDate, Utc};

use crate::error::ApiError;

pub const COUNTER_MAX: i64 = 1_000_000;

/// The first day of the week containing `date`, for a week starting on
/// `week_start` (1 = Monday ... 7 = Sunday).
pub fn week_start_date(date: NaiveDate, week_start: i64) -> NaiveDate {
    let weekday = i64::from(date.weekday().number_from_monday());
    date - Days::new((weekday - week_start).rem_euclid(7) as u64)
}

/// What a habit's goal is measured over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Period {
    Day,
    /// This many weeks, in blocks counted from the week of the second date.
    Weeks(i64, NaiveDate),
    /// This many calendar months, in blocks counted from January: 3 is a
    /// quarter, 12 a year.
    Months(i64),
}

impl Period {
    /// The period a schedule measures on. Only target schedules have `every`.
    pub fn of(schedule: &str, every: i64) -> Self {
        match schedule {
            // 1970-01-05 is a Monday; without an anchor any fixed week will do.
            "weekly" => Self::Weeks(every, NaiveDate::from_ymd_opt(1970, 1, 5).unwrap()),
            "monthly" => Self::Months(every),
            "yearly" => Self::Months(12 * every),
            _ => Self::Day,
        }
    }

    /// The period with its blocks of weeks counted from the week `anchor` is
    /// in: the day the schedule was set, so that its first block is a whole one.
    pub fn anchored(self, anchor: Option<NaiveDate>) -> Self {
        match (self, anchor) {
            (Self::Weeks(count, _), Some(anchor)) => Self::Weeks(count, anchor),
            _ => self,
        }
    }

    /// The first day of the period containing `date`.
    pub fn start(self, date: NaiveDate, week_start: i64) -> NaiveDate {
        match self {
            Self::Day => date,
            Self::Weeks(count, anchor) => {
                let origin = week_start_date(anchor, week_start);
                let week = week_start_date(date, week_start);
                let weeks = (week - origin).num_days() / 7;
                week - Days::new(weeks.rem_euclid(count) as u64 * 7)
            }
            Self::Months(count) => {
                let month = i64::from(date.year()) * 12 + i64::from(date.month0());
                first_of_month(month - month.rem_euclid(count))
            }
        }
    }

    /// The last day of the period containing `date`.
    pub fn end(self, date: NaiveDate, week_start: i64) -> NaiveDate {
        let start = self.start(date, week_start);
        match self {
            Self::Day => start,
            Self::Weeks(count, _) => start + Days::new(count as u64 * 7 - 1),
            Self::Months(count) => {
                let month = i64::from(start.year()) * 12 + i64::from(start.month0());
                first_of_month(month + count) - Days::new(1)
            }
        }
    }

    /// The most days a yes/no habit can be asked for in one period.
    fn max_days(self) -> i64 {
        match self {
            Self::Day => 1,
            Self::Weeks(count, _) => 7 * count,
            Self::Months(count) => 365 * count / 12,
        }
    }
}

/// The first day of a month numbered from year 0, January = 0.
fn first_of_month(month: i64) -> NaiveDate {
    NaiveDate::from_ymd_opt(month.div_euclid(12) as i32, month.rem_euclid(12) as u32 + 1, 1)
        .expect("a month within chrono's range")
}

/// The most weeks, months or years one period can span.
pub const MAX_EVERY: i64 = 52;

/// The most days an `interval` habit can rest between two times.
pub const MAX_INTERVAL: i64 = 365;

pub fn is_target(schedule: &str) -> bool {
    matches!(schedule, "weekly" | "monthly" | "yearly")
}

/// Checks how many weeks, months or years a target counts as one period, or
/// how many days an interval lasts.
pub fn validate_every(schedule: &str, every: i64) -> Result<(), ApiError> {
    if schedule == "interval" {
        if !(1..=MAX_INTERVAL).contains(&every) {
            return Err(ApiError::validation("an interval is from 1 to 365 days"));
        }
        return Ok(());
    }
    if !(1..=MAX_EVERY).contains(&every) {
        return Err(ApiError::validation("every must be a number from 1 to 52"));
    }
    if every != 1 && !is_target(schedule) {
        return Err(ApiError::validation(
            "every must be 1 unless the schedule is weekly, monthly, yearly or interval",
        ));
    }
    Ok(())
}

/// Whether a habit is due on `date`. Only a `weekdays` habit is ever not due.
pub fn is_due(weekdays: Option<i64>, date: NaiveDate) -> bool {
    match weekdays {
        Some(mask) => mask & (1 << date.weekday().num_days_from_monday()) != 0,
        None => true,
    }
}

/// The largest value one day can hold.
pub fn max_value(kind: &str) -> i64 {
    if kind == "boolean" { 1 } else { COUNTER_MAX }
}

/// Weekday numbers (1 = Monday ... 7 = Sunday) to the database bitmask.
pub fn weekdays_to_mask(days: &[i64]) -> Result<i64, ApiError> {
    let mut mask = 0;
    for &day in days {
        if !(1..=7).contains(&day) {
            return Err(ApiError::validation("weekdays must be numbers from 1 to 7"));
        }
        mask |= 1 << (day - 1);
    }
    if mask == 0 {
        return Err(ApiError::validation("weekdays must list at least one day"));
    }
    Ok(mask)
}

pub fn mask_to_weekdays(mask: i64) -> Vec<i64> {
    (1..=7).filter(|day| mask & (1 << (day - 1)) != 0).collect()
}

/// Checks the kind, schedule and goal combination against the rules in section 4.
pub fn validate_goal(kind: &str, schedule: &str, every: i64, goal: i64) -> Result<(), ApiError> {
    if goal < 1 {
        return Err(ApiError::validation("goal must be at least 1"));
    }
    if kind == "boolean" {
        if !is_target(schedule) && goal != 1 {
            return Err(ApiError::validation(
                "a boolean habit's goal must be 1 unless it is weekly, monthly or yearly",
            ));
        }
        if goal > Period::of(schedule, every).max_days() {
            return Err(ApiError::validation(
                "a boolean habit's goal is in days, and its period does not have that many",
            ));
        }
    }
    Ok(())
}

/// Parses a strict `YYYY-MM-DD` date.
pub fn parse_date(raw: &str) -> Result<NaiveDate, ApiError> {
    (raw.len() == 10)
        .then(|| NaiveDate::parse_from_str(raw, "%Y-%m-%d").ok())
        .flatten()
        .ok_or_else(|| ApiError::validation("date must be a real calendar date, YYYY-MM-DD"))
}

/// Parses a date that may be written to: no later than tomorrow (UTC).
pub fn parse_writable_date(raw: &str) -> Result<NaiveDate, ApiError> {
    let date = parse_date(raw)?;
    if date > Utc::now().date_naive() + Days::new(1) {
        return Err(ApiError::validation("date must not be later than tomorrow"));
    }
    Ok(date)
}

/// Today's date in an IANA time zone (UTC if the name is unknown).
pub fn today_in(timezone: &str) -> NaiveDate {
    let tz: chrono_tz::Tz = timezone.parse().unwrap_or(chrono_tz::UTC);
    Utc::now().with_timezone(&tz).date_naive()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        parse_date(s).unwrap()
    }

    #[test]
    fn week_start_for_every_start_day() {
        // 2026-10-07 is a Wednesday.
        let wednesday = d("2026-10-07");
        let expected = [
            (1, "2026-10-05"),
            (2, "2026-10-06"),
            (3, "2026-10-07"),
            (4, "2026-10-01"),
            (5, "2026-10-02"),
            (6, "2026-10-03"),
            (7, "2026-10-04"),
        ];
        for (week_start, start) in expected {
            assert_eq!(week_start_date(wednesday, week_start), d(start), "week_start {week_start}");
        }
    }

    #[test]
    fn week_start_is_stable_across_the_week() {
        for week_start in 1..=7 {
            let start = week_start_date(d("2026-10-07"), week_start);
            for offset in 0..7 {
                assert_eq!(week_start_date(start + Days::new(offset), week_start), start);
            }
            assert_ne!(week_start_date(start + Days::new(7), week_start), start);
        }
    }

    #[test]
    fn due_days_follow_the_mask() {
        let mask = weekdays_to_mask(&[1, 3, 7]).unwrap();
        assert_eq!(mask, 0b1000101);
        assert_eq!(mask_to_weekdays(mask), vec![1, 3, 7]);
        assert!(is_due(Some(mask), d("2026-10-05"))); // Monday
        assert!(!is_due(Some(mask), d("2026-10-06"))); // Tuesday
        assert!(is_due(Some(mask), d("2026-10-07"))); // Wednesday
        assert!(is_due(Some(mask), d("2026-10-04"))); // Sunday
        assert!(is_due(None, d("2026-10-06")));
    }

    #[test]
    fn weekday_lists_are_validated() {
        assert!(weekdays_to_mask(&[]).is_err());
        assert!(weekdays_to_mask(&[0]).is_err());
        assert!(weekdays_to_mask(&[8]).is_err());
        assert_eq!(weekdays_to_mask(&[2, 2]).unwrap(), 0b10);
    }

    #[test]
    fn goal_rules() {
        assert!(validate_goal("boolean", "daily", 1, 1).is_ok());
        assert!(validate_goal("boolean", "daily", 1, 2).is_err());
        assert!(validate_goal("boolean", "weekdays", 1, 2).is_err());
        assert!(validate_goal("boolean", "weekly", 1, 7).is_ok());
        assert!(validate_goal("boolean", "weekly", 1, 8).is_err());
        assert!(validate_goal("boolean", "weekly", 2, 14).is_ok());
        assert!(validate_goal("boolean", "monthly", 1, 30).is_ok());
        assert!(validate_goal("boolean", "monthly", 1, 31).is_err());
        assert!(validate_goal("boolean", "yearly", 1, 365).is_ok());
        assert!(validate_goal("boolean", "yearly", 1, 366).is_err());
        assert!(validate_goal("counter", "daily", 1, 500).is_ok());
        assert!(validate_goal("counter", "weekly", 1, 0).is_err());
    }

    #[test]
    fn every_is_only_for_targets() {
        assert!(validate_every("daily", 1).is_ok());
        assert!(validate_every("daily", 2).is_err());
        assert!(validate_every("weekdays", 2).is_err());
        assert!(validate_every("monthly", 3).is_ok());
        assert!(validate_every("weekly", 0).is_err());
        assert!(validate_every("yearly", 53).is_err());
        assert!(validate_every("interval", 90).is_ok());
        assert!(validate_every("interval", 366).is_err());
    }

    #[test]
    fn periods_follow_the_calendar() {
        let bounds = |period: Period, date: &str| {
            (period.start(d(date), 1).to_string(), period.end(d(date), 1).to_string())
        };
        let pair = |start: &str, end: &str| (start.to_string(), end.to_string());
        assert_eq!(bounds(Period::Day, "2026-10-07"), pair("2026-10-07", "2026-10-07"));
        assert_eq!(bounds(Period::of("weekly", 1), "2026-10-07"), pair("2026-10-05", "2026-10-11"));
        assert_eq!(
            bounds(Period::of("monthly", 1), "2026-02-14"),
            pair("2026-02-01", "2026-02-28")
        );
        assert_eq!(
            bounds(Period::of("monthly", 1), "2028-02-29"),
            pair("2028-02-01", "2028-02-29")
        );
        // Three months are a calendar quarter.
        assert_eq!(
            bounds(Period::of("monthly", 3), "2026-11-30"),
            pair("2026-10-01", "2026-12-31")
        );
        assert_eq!(bounds(Period::of("yearly", 1), "2026-10-07"), pair("2026-01-01", "2026-12-31"));
        assert_eq!(bounds(Period::of("yearly", 2), "2027-06-01"), pair("2026-01-01", "2027-12-31"));
    }

    #[test]
    fn several_weeks_are_one_block() {
        let period = Period::of("weekly", 2);
        for week_start in 1..=7 {
            let start = period.start(d("2026-10-07"), week_start);
            assert_eq!(start, week_start_date(start, week_start));
            assert_eq!(period.end(d("2026-10-07"), week_start), start + Days::new(13));
            for offset in 0..14 {
                assert_eq!(period.start(start + Days::new(offset), week_start), start);
            }
            assert_eq!(period.start(start + Days::new(14), week_start), start + Days::new(14));
            assert_eq!(period.start(start - Days::new(1), week_start), start - Days::new(14));

            // Anchored, the block starts with the week the anchor is in.
            for anchor in ["2026-10-07", "2026-10-14", "2026-09-30"] {
                let anchored = period.anchored(Some(d(anchor)));
                let week = week_start_date(d(anchor), week_start);
                assert_eq!(anchored.start(d(anchor), week_start), week);
                assert_eq!(anchored.end(d(anchor), week_start), week + Days::new(13));
                assert_eq!(anchored.start(week - Days::new(1), week_start), week - Days::new(14));
            }
        }
        // Only blocks of weeks have an anchor.
        let quarter = Period::of("monthly", 3).anchored(Some(d("2026-11-30")));
        assert_eq!(quarter.start(d("2026-11-30"), 1), d("2026-10-01"));
    }

    #[test]
    fn dates_are_strict() {
        assert!(parse_date("2026-02-29").is_err());
        assert!(parse_date("2026-2-9").is_err());
        assert!(parse_date("2026-10-04T00").is_err());
        assert!(parse_date("2028-02-29").is_ok());
        assert!(parse_writable_date("2999-01-01").is_err());
    }
}
