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
pub fn validate_goal(kind: &str, schedule: &str, goal: i64) -> Result<(), ApiError> {
    if goal < 1 {
        return Err(ApiError::validation("goal must be at least 1"));
    }
    if kind == "boolean" {
        if schedule == "weekly" && goal > 7 {
            return Err(ApiError::validation(
                "a weekly boolean habit's goal is 1 to 7 days per week",
            ));
        }
        if schedule != "weekly" && goal != 1 {
            return Err(ApiError::validation(
                "a boolean habit's goal must be 1 unless it is weekly",
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
        assert!(validate_goal("boolean", "daily", 1).is_ok());
        assert!(validate_goal("boolean", "daily", 2).is_err());
        assert!(validate_goal("boolean", "weekdays", 2).is_err());
        assert!(validate_goal("boolean", "weekly", 7).is_ok());
        assert!(validate_goal("boolean", "weekly", 8).is_err());
        assert!(validate_goal("counter", "daily", 500).is_ok());
        assert!(validate_goal("counter", "weekly", 0).is_err());
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
