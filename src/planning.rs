//! Org planning timestamps: the value type of the `scheduled` field, and
//! of a later DEADLINE field on the same paths.
//!
//! A stored value is a normalised Org timestamp body without brackets or
//! weekday: `YYYY-MM-DD[ HH:MM[-HH:MM]][ REPEATER][ DELAY]`. Repeaters and
//! delays are kept as written text and never interpreted. Times float: no
//! time zone. Only live writes check the form; replay keeps whatever a log
//! holds.

use crate::state::{RejectCode, Rejection};

/// A calendar date in the proleptic Gregorian calendar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Date {
    pub year: i64,
    pub month: u32,
    pub day: u32,
}

impl Date {
    /// The date `days` days after 1970-01-01 (Howard Hinnant's
    /// days-to-civil algorithm).
    pub fn from_days(days: i64) -> Date {
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let y = yoe + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
        let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
        Date {
            year: if month <= 2 { y + 1 } else { y },
            month,
            day,
        }
    }

    /// Days since 1970-01-01; the inverse of [`Date::from_days`].
    pub fn days(self) -> i64 {
        let y = if self.month <= 2 {
            self.year - 1
        } else {
            self.year
        };
        let era = y.div_euclid(400);
        let yoe = y.rem_euclid(400);
        let m = self.month as i64;
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + self.day as i64 - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146_097 + doe - 719_468
    }

    /// The English three-letter weekday name.
    pub fn weekday(self) -> &'static str {
        // 1970-01-01 was a Thursday.
        ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][self.days().rem_euclid(7) as usize]
    }

    fn valid(self) -> bool {
        (1..=12).contains(&self.month)
            && (1..=days_in_month(self.year, self.month)).contains(&self.day)
    }

    /// This date `n` calendar months later, clamped to the end of the
    /// target month: 01-31 plus one month is 02-28, or 02-29 in a leap year.
    fn add_months(self, n: i64) -> Date {
        let index = self.year * 12 + (self.month as i64 - 1) + n;
        let year = index.div_euclid(12);
        let month = (index.rem_euclid(12) + 1) as u32;
        Date {
            year,
            month,
            day: self.day.min(days_in_month(year, month)),
        }
    }
}

impl std::fmt::Display for Date {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        _ => 28,
    }
}

/// A time of day as (hour, minute).
pub type HourMinute = (u32, u32);

/// A start time and an optional end time.
pub type TimeRange = (HourMinute, Option<HourMinute>);

/// A parsed planning timestamp.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timestamp {
    pub date: Date,
    pub time: Option<TimeRange>,
    /// `+1w`, `.+2d`, `++1m/3m`, as written.
    pub repeater: Option<String>,
    /// `-2d`, `--1w`, as written.
    pub delay: Option<String>,
}

fn reject(message: impl Into<String>) -> Rejection {
    Rejection {
        code: RejectCode::InvalidTimestamp,
        message: message.into(),
    }
}

fn digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

fn parse_date(token: &str) -> Option<Date> {
    let b = token.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let (y, m, d) = (&token[..4], &token[5..7], &token[8..]);
    if !(digits(y) && digits(m) && digits(d)) {
        return None;
    }
    Some(Date {
        year: y.parse().ok()?,
        month: m.parse().ok()?,
        day: d.parse().ok()?,
    })
}

/// `H:MM` or `HH:MM`; `Some(Err)` for the right shape but an impossible
/// time.
fn parse_clock(s: &str) -> Option<Result<HourMinute, Rejection>> {
    let (h, m) = s.split_once(':')?;
    if !(digits(h) && h.len() <= 2 && digits(m) && m.len() == 2) {
        return None;
    }
    let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
    Some(if h > 23 || m > 59 {
        Err(reject(format!("{s:?} is not a time of day")))
    } else {
        Ok((h, m))
    })
}

/// A time or time range token, as [`parse_clock`].
fn parse_time(token: &str) -> Option<Result<TimeRange, Rejection>> {
    match token.split_once('-') {
        None => Some(parse_clock(token)?.map(|t| (t, None))),
        Some((a, b)) => {
            let (a, b) = (parse_clock(a)?, parse_clock(b)?);
            Some(a.and_then(|a| b.map(|b| (a, Some(b)))))
        }
    }
}

/// A count and a one-letter ASCII unit, such as `3d`. The unit is checked
/// first, so the count ends on a character boundary whatever `s` holds.
fn count_and_unit(s: &str, units: &[u8]) -> bool {
    s.as_bytes()
        .split_last()
        .is_some_and(|(unit, count)| units.contains(unit) && !count.is_empty())
        && digits(&s[..s.len() - 1])
}

const UNITS: &[u8] = b"hdwmy";

fn is_repeater(token: &str) -> bool {
    let rest = token
        .strip_prefix(".+")
        .or_else(|| token.strip_prefix("++"))
        .or_else(|| token.strip_prefix('+'));
    rest.is_some_and(|r| match r.split_once('/') {
        Some((a, b)) => count_and_unit(a, UNITS) && count_and_unit(b, UNITS),
        None => count_and_unit(r, UNITS),
    })
}

fn is_delay(token: &str) -> bool {
    token
        .strip_prefix("--")
        .or_else(|| token.strip_prefix('-'))
        .is_some_and(|r| count_and_unit(r, UNITS))
}

/// One word of the weekday Org writes after the date, its `%a` in the
/// reader's locale: `Thu`, `do`, `jeu.`, `T5`, `ה'`, the two words of
/// `Aso Tof`, `सोम:`. Every such word starts with something other than
/// an ASCII digit, `+`, `-` or `.`, which is how the time, repeater or
/// delay after it starts, so the weekday is the words before the first
/// of those. A word holding `+`, `-` or a time (`Thu+1w`, which Org reads
/// as a repeater) is never weekday, so no part of a timestamp is dropped
/// with it: such a word is refused. Brackets end a timestamp and are
/// never part of it.
fn is_weekday_word(token: &str) -> bool {
    let b = token.as_bytes();
    b.first()
        .is_some_and(|c| !(c.is_ascii_digit() || matches!(c, b'+' | b'-' | b'.')))
        && !b
            .iter()
            .any(|c| matches!(c, b'+' | b'-' | b'<' | b'>' | b'[' | b']'))
        && !b
            .windows(3)
            .any(|w| w[0].is_ascii_digit() && w[1] == b':' && w[2].is_ascii_digit())
}

/// The words of a timestamp body, split at any Unicode white space: some
/// locales' weekdays end in a no-break space (`lv_LV` writes `C\u{a0}`),
/// and no separator may hide a time inside a dropped word.
fn words(body: &str) -> impl Iterator<Item = &str> {
    body.split_whitespace()
}

/// The body of an Org timestamp the user typed or pasted, with brackets
/// `<...>` taken off. Inactive, range and sexp forms are refused, since a
/// planning value is always one active timestamp.
fn strip_brackets(input: &str) -> Result<&str, Rejection> {
    let s = input.trim();
    if s.starts_with('[') {
        return Err(reject(format!(
            "{s:?} is an inactive timestamp; a planning date is always active, write it without brackets or with <...>"
        )));
    }
    if s.contains(">--<") || s.contains("]--[") {
        return Err(reject(format!(
            "{s:?} is a range of timestamps; a planning date is one timestamp"
        )));
    }
    let s = match s.strip_prefix('<') {
        Some(inner) => inner
            .strip_suffix('>')
            .ok_or_else(|| reject(format!("{s:?} opens < without closing it")))?,
        None => s,
    };
    if s.starts_with("%%") {
        return Err(reject(format!(
            "{s:?} is a diary sexp; a planning date is a calendar date"
        )));
    }
    Ok(s.trim())
}

impl Timestamp {
    /// Parses an absolute timestamp body, already without brackets:
    /// date, an optional weekday of any number of words (ignored), an
    /// optional time or time range, then at most one repeater and one
    /// delay, in either order.
    pub fn parse(body: &str) -> Result<Timestamp, Rejection> {
        let mut tokens = words(body).peekable();
        let first = tokens
            .next()
            .ok_or_else(|| reject("a timestamp needs a date, such as 2026-12-03"))?;
        let date = parse_date(first)
            .ok_or_else(|| reject(format!("{first:?} is not a date; write it as YYYY-MM-DD")))?;
        if !date.valid() {
            return Err(reject(format!("{first} is not a date in the calendar")));
        }
        while tokens.next_if(|t| is_weekday_word(t)).is_some() {}
        let mut time = None;
        if let Some(parsed) = tokens.peek().and_then(|t| parse_time(t)) {
            time = Some(parsed?);
            tokens.next();
        }
        let (mut repeater, mut delay) = (None, None);
        for token in tokens {
            let slot = if is_repeater(token) {
                &mut repeater
            } else if is_delay(token) {
                &mut delay
            } else {
                return Err(reject(format!(
                    "{token:?} in {body:?} is not a time, repeater (+1w, .+1d, ++1m) or delay (-2d)"
                )));
            };
            if slot.is_some() {
                return Err(reject(format!("{body:?} has two repeaters or two delays")));
            }
            *slot = Some(token.to_string());
        }
        Ok(Timestamp {
            date,
            time,
            repeater,
            delay,
        })
    }

    /// The stored, normalised form.
    pub fn value(&self) -> String {
        self.text(false)
    }

    /// The form people read: the stored one with an English weekday after
    /// the date, as Org would show it.
    pub fn display(&self) -> String {
        self.text(true)
    }

    fn text(&self, weekday: bool) -> String {
        let mut out = self.date.to_string();
        if weekday {
            out.push(' ');
            out.push_str(self.date.weekday());
        }
        if let Some(((h, m), end)) = self.time {
            out.push_str(&format!(" {h:02}:{m:02}"));
            if let Some((h, m)) = end {
                out.push_str(&format!("-{h:02}:{m:02}"));
            }
        }
        for part in [&self.repeater, &self.delay].into_iter().flatten() {
            out.push(' ');
            out.push_str(part);
        }
        out
    }
}

/// Checks that `value` is a stored value in normalised form, as every live
/// write must be.
pub fn check_value(value: &str) -> Result<(), Rejection> {
    let parsed = Timestamp::parse(value)?;
    if parsed.value() != value {
        return Err(reject(format!(
            "{value:?} is not in normalised form; write {:?}",
            parsed.value()
        )));
    }
    Ok(())
}

/// How a stored value reads with its weekday, or the value as it is when
/// it is not in the form this build knows.
pub fn display(value: &str) -> String {
    Timestamp::parse(value)
        .ok()
        .filter(|t| t.value() == value)
        .map_or_else(|| value.to_string(), |t| t.display())
}

/// Resolves what a user or client typed to the stored value: an absolute
/// timestamp (brackets and weekday dropped), or a relative date as the
/// first token (`today`, `.`, `tomorrow`, `+N` with a unit `d w m y`),
/// optionally followed by a time, against `today`, the local date where
/// the CLI runs.
pub fn resolve_input(input: &str, today: Date) -> Result<String, Rejection> {
    let body = strip_brackets(input)?;
    let mut tokens = words(body);
    let Some(first) = tokens.next() else {
        return Err(reject(
            "a timestamp needs a date, such as 2026-12-03 or +3d",
        ));
    };
    let Some(date) = relative(first, today)? else {
        return Ok(Timestamp::parse(body)?.value());
    };
    let rest: Vec<&str> = tokens.collect();
    let time = match rest.as_slice() {
        [] => None,
        [t] => Some(parse_time(t).ok_or_else(|| {
            reject(format!(
                "{t:?} after the relative date {first:?} is not a time; a relative date takes no repeater or delay"
            ))
        })??),
        _ => {
            return Err(reject(format!(
                "{body:?}: a relative date takes at most a time; write an absolute date for a repeater or delay"
            )));
        }
    };
    if date.year > 9999 {
        return Err(reject(format!("{first:?} lands after the year 9999")));
    }
    Ok(Timestamp {
        date,
        time,
        repeater: None,
        delay: None,
    }
    .value())
}

/// The date a relative first token names, `None` when it is not one.
fn relative(token: &str, today: Date) -> Result<Option<Date>, Rejection> {
    let lower = token.to_ascii_lowercase();
    match lower.as_str() {
        "today" | "." => return Ok(Some(today)),
        "tomorrow" => return Ok(Some(Date::from_days(today.days() + 1))),
        _ => {}
    }
    let Some(rest) = token.strip_prefix('+') else {
        return Ok(None);
    };
    if !count_and_unit(rest, b"dwmy") {
        return Err(reject(format!(
            "{token:?} is not a relative date; write +N with d, w, m or y, such as +3d"
        )));
    }
    let n: i64 = rest[..rest.len() - 1]
        .parse()
        .ok()
        .filter(|n| *n <= 1_000_000)
        .ok_or_else(|| reject(format!("{token:?} is too far ahead")))?;
    Ok(Some(match rest.as_bytes()[rest.len() - 1] {
        b'd' => Date::from_days(today.days() + n),
        b'w' => Date::from_days(today.days() + 7 * n),
        b'm' => today.add_months(n),
        _ => today.add_months(12 * n),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i64, month: u32, day: u32) -> Date {
        Date { year, month, day }
    }

    fn resolve(input: &str) -> Result<String, Rejection> {
        resolve_input(input, date(2026, 11, 26))
    }

    fn refused(input: &str) -> String {
        let r = resolve(input).expect_err(input);
        assert_eq!(r.code, RejectCode::InvalidTimestamp, "{input}");
        r.message
    }

    #[test]
    fn days_round_trip_and_weekdays() {
        for days in [-800_000, -1, 0, 1, 20_000, 20_788, 2_000_000] {
            assert_eq!(Date::from_days(days).days(), days);
        }
        assert_eq!(date(1970, 1, 1).days(), 0);
        assert_eq!(date(2026, 12, 3).weekday(), "Thu");
        assert_eq!(date(2024, 2, 29).weekday(), "Thu");
        assert_eq!(date(2026, 11, 29).weekday(), "Sun");
        assert_eq!(date(1969, 12, 31).weekday(), "Wed");
    }

    #[test]
    fn absolute_input_is_normalised() {
        for (input, value) in [
            ("2026-12-03", "2026-12-03"),
            ("  2026-12-03 ", "2026-12-03"),
            ("<2026-12-03 Thu>", "2026-12-03"),
            ("<2026-12-03 Thu 10:00>", "2026-12-03 10:00"),
            ("2026-12-03 9:05", "2026-12-03 09:05"),
            ("<2026-12-03 do 10:00-11:30>", "2026-12-03 10:00-11:30"),
            ("2026-12-03 jeu. 10:00 +1w", "2026-12-03 10:00 +1w"),
            ("2026-12-03 Mon", "2026-12-03"),
            ("2026-12-03 +1w -2d", "2026-12-03 +1w -2d"),
            ("2026-12-03 -2d .+1m", "2026-12-03 .+1m -2d"),
            ("2026-12-03 ++1y --3d", "2026-12-03 ++1y --3d"),
            ("2026-12-03 .+1d/3d", "2026-12-03 .+1d/3d"),
            ("2026-12-03 +2h", "2026-12-03 +2h"),
            ("2024-02-29", "2024-02-29"),
            ("2000-02-29", "2000-02-29"),
            // Weekdays as glibc's %a writes them for Thursday in vi_VN,
            // he_IL, sm_WS, hi_IN, am_ET (with its trailing blank) and
            // es_PH-like `#` forms.
            ("<2026-12-03 T5 10:00 +1w>", "2026-12-03 10:00 +1w"),
            ("<2026-12-03 ה' 10:00 +1w>", "2026-12-03 10:00 +1w"),
            ("<2026-12-03 Aso Tof 10:00 +1w>", "2026-12-03 10:00 +1w"),
            ("<2026-12-03 Aso To' -2d>", "2026-12-03 -2d"),
            ("2026-12-03 सोम: 9:00", "2026-12-03 09:00"),
            ("<2026-12-03 ሰኞ  .+1d>", "2026-12-03 .+1d"),
            ("2026-12-03 suno esun #4 ++1m", "2026-12-03 ++1m"),
            ("2026-12-03 Thu Fri", "2026-12-03"),
            // lv_LV ends its weekday in a no-break space.
            ("<2026-12-03 C\u{a0} 10:00>", "2026-12-03 10:00"),
            ("<2026-12-03 C\u{a0}>", "2026-12-03"),
            // Any white space separates words, so none hides a time.
            ("2026-12-03 Thu\n10:00", "2026-12-03 10:00"),
            ("2026-12-03 Thu\u{a0}10:00 +1w", "2026-12-03 10:00 +1w"),
            ("2026-12-03\u{3000}Thu\u{2009}-2d", "2026-12-03 -2d"),
        ] {
            assert_eq!(resolve(input).as_deref(), Ok(value), "{input}");
        }
    }

    #[test]
    fn impossible_and_unrepresentable_input_is_refused() {
        for input in [
            "2026-02-30",
            "2026-13-01",
            "2026-00-10",
            "2026-04-31",
            "2025-02-29",
            "1900-02-29",
            "2026-12-03 24:00",
            "2026-12-03 10:60",
            "2026-12-03 10:00-25:00",
            "2026-12-3",
            "26-12-03",
            "",
            "   ",
            "next week",
            "2026-12-03 +1w +2w",
            "2026-12-03 -1d -2d",
            "2026-12-03 10:00 11:00",
            "2026-12-03 +1x",
            "<2026-12-03 Thu",
            "2026-12-03 Thu 10:00 Fri",
            "2026-12-03 T<5",
            "2026-12-03 .5",
            // Org reads these as a weekday with a repeater, delay or
            // time; dropping the word would drop that too.
            "<2026-12-03 Thu+1w>",
            "<2026-12-03 Thu.+1d>",
            "<2026-12-03 Thu-2d>",
            "<2026-12-03 Thu10:00>",
            "2026-12-03 Thu\u{1}10:00",
            "2026-12-03 Aso Tof+1w",
        ] {
            refused(input);
        }
        assert!(refused("[2026-12-03 Thu]").contains("inactive"));
        assert!(refused("<2026-12-03 Thu>--<2026-12-05 Sat>").contains("range"));
        assert!(refused("<%%(diary-float t 4 2)>").contains("sexp"));
    }

    #[test]
    fn relative_input_resolves_against_today() {
        for (input, value) in [
            ("today", "2026-11-26"),
            (".", "2026-11-26"),
            ("TODAY", "2026-11-26"),
            ("tomorrow", "2026-11-27"),
            ("+0d", "2026-11-26"),
            ("+7d", "2026-12-03"),
            ("+2w", "2026-12-10"),
            ("+1m", "2026-12-26"),
            ("+2m", "2027-01-26"),
            ("+1y", "2027-11-26"),
            ("tomorrow 10:00", "2026-11-27 10:00"),
            ("+3d 9:00-10:30", "2026-11-29 09:00-10:30"),
            ("<+1d>", "2026-11-27"),
        ] {
            assert_eq!(resolve(input).as_deref(), Ok(value), "{input}");
        }
        // A relative date takes a time, never a repeater or delay.
        refused("today +1w");
        refused("+3d -1d");
        refused("tomorrow 10:00 +1w");
        refused("+3");
        refused("+3h");
        refused("today 25:00");
    }

    #[test]
    fn non_ascii_where_a_unit_goes_is_refused_not_a_panic() {
        for input in [
            "+1é",
            "+é",
            "+1ď",
            "2026-12-03 +1é",
            "2026-12-03 -1é",
            "2026-12-03 .+1d/2é",
            "2026-12-03 ++é",
            "2026-12-03 10:00 +日",
            "2026-12-03 Thu +1日",
        ] {
            refused(input);
            assert!(check_value(input).is_err(), "{input}");
        }
        // Values replay keeps are shown as stored.
        assert_eq!(display("2026-12-03 +1é"), "2026-12-03 +1é");
        assert_eq!(display("2026-12-03 -日"), "2026-12-03 -日");
        assert_eq!(display("+1é"), "+1é");
    }

    #[test]
    fn months_and_years_clamp_to_the_month_end() {
        let from = |d: Date, input: &str| resolve_input(input, d).unwrap();
        assert_eq!(from(date(2026, 1, 31), "+1m"), "2026-02-28");
        assert_eq!(from(date(2028, 1, 31), "+1m"), "2028-02-29");
        assert_eq!(from(date(2026, 3, 31), "+1m"), "2026-04-30");
        assert_eq!(from(date(2026, 12, 31), "+2m"), "2027-02-28");
        assert_eq!(from(date(2026, 8, 31), "+6m"), "2027-02-28");
        assert_eq!(from(date(2028, 2, 29), "+1y"), "2029-02-28");
        assert_eq!(from(date(2028, 2, 29), "+4y"), "2032-02-29");
        assert_eq!(from(date(2026, 12, 31), "tomorrow"), "2027-01-01");
        assert_eq!(from(date(2026, 2, 28), "+1d"), "2026-03-01");
        assert!(resolve_input("+9000y", date(2026, 1, 1)).is_err());
    }

    #[test]
    fn stored_values_must_be_normalised() {
        assert!(check_value("2026-12-03").is_ok());
        assert!(check_value("2026-12-03 10:00-11:00 +1w -2d").is_ok());
        for value in [
            "2026-12-03 Thu",
            "2026-12-03 9:00",
            "<2026-12-03>",
            "2026-12-03  10:00",
            "2026-12-03 -2d +1w",
            "2026-02-30",
            "tomorrow",
        ] {
            assert!(check_value(value).is_err(), "{value}");
        }
    }

    #[test]
    fn display_adds_the_weekday() {
        assert_eq!(display("2026-12-03"), "2026-12-03 Thu");
        assert_eq!(display("2026-12-03 10:00 +1w"), "2026-12-03 Thu 10:00 +1w");
        // A value outside this build's form is shown as stored.
        assert_eq!(display("2026-12-03 sometime"), "2026-12-03 sometime");
    }
}
