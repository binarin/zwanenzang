//! The hybrid logical clock behind event ids, and the wall clock used for the
//! informational `ts` field. The clock is a trait so tests can make the wall
//! clock lag or stand still.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::ulid::{RANDOM_MAX, TIME_MAX, Ulid};

pub trait Clock {
    /// Wall-clock milliseconds since the Unix epoch.
    fn now_ms(&mut self) -> u64;
    /// 80 fresh random bits.
    fn random80(&mut self) -> u128;
}

/// The real clock: system time and the operating system's random source.
#[derive(Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&mut self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    fn random80(&mut self) -> u128 {
        let mut buf = [0u8; 16];
        getrandom::fill(&mut buf).expect("operating system random source");
        u128::from_le_bytes(buf) & RANDOM_MAX
    }
}

/// Returns a new id that sorts after `highest_seen`.
///
/// The time part is `max(now, highest_seen.time)`. When that equals the
/// highest seen id's time, the random part is the seen random part plus one;
/// otherwise it is fresh random.
pub fn next_id(clock: &mut dyn Clock, highest_seen: Option<Ulid>) -> Ulid {
    let now = clock.now_ms().min(TIME_MAX);
    let Some(seen) = highest_seen else {
        return Ulid::from_parts(now, clock.random80());
    };
    let seen_t = seen.time_ms();
    if now > seen_t {
        return Ulid::from_parts(now, clock.random80());
    }
    if seen.random() < RANDOM_MAX {
        Ulid::from_parts(seen_t, seen.random() + 1)
    } else {
        // The random part is exhausted within this millisecond; move to the
        // next one. Practically unreachable. At the very last millisecond
        // there is no later id; the result then fails validation as not
        // sorting after its parent instead of overflowing.
        Ulid::from_parts((seen_t + 1).min(TIME_MAX), clock.random80())
    }
}

/// Formats milliseconds since the epoch as RFC 3339 UTC with second
/// precision, e.g. `2026-11-07T12:34:56Z`.
pub fn format_ts(ms: u64) -> String {
    let secs = ms / 1000;
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem / 60) % 60,
        rem % 60
    )
}

/// Howard Hinnant's days-to-civil algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// A deterministic clock for tests: a settable wall clock and a counter as
/// the random source.
#[derive(Debug, Clone)]
pub struct FixedClock {
    pub now: u64,
    pub next_random: u128,
}

impl FixedClock {
    pub fn new(now: u64) -> FixedClock {
        FixedClock {
            now,
            next_random: 1000,
        }
    }
}

impl Clock for FixedClock {
    fn now_ms(&mut self) -> u64 {
        self.now
    }

    fn random80(&mut self) -> u128 {
        self.next_random += 1000;
        self.next_random & RANDOM_MAX
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_id_uses_wall_clock() {
        let mut c = FixedClock::new(5_000);
        let id = next_id(&mut c, None);
        assert_eq!(id.time_ms(), 5_000);
    }

    #[test]
    fn ahead_wall_clock_takes_fresh_random() {
        let mut c = FixedClock::new(5_000);
        let seen = Ulid::from_parts(4_000, RANDOM_MAX - 3);
        let id = next_id(&mut c, Some(seen));
        assert_eq!(id.time_ms(), 5_000);
        assert!(id > seen);
    }

    #[test]
    fn lagging_wall_clock_bumps_past_seen() {
        let mut c = FixedClock::new(1_000);
        let seen = Ulid::from_parts(9_000, 41);
        let id = next_id(&mut c, Some(seen));
        assert_eq!(id, Ulid::from_parts(9_000, 42));
        // A run of ids with a stuck clock stays strictly increasing.
        let mut prev = id;
        for _ in 0..100 {
            let n = next_id(&mut c, Some(prev));
            assert!(n > prev);
            assert_eq!(n.time_ms(), 9_000);
            prev = n;
        }
    }

    #[test]
    fn same_millisecond_increments_random() {
        let mut c = FixedClock::new(9_000);
        let seen = Ulid::from_parts(9_000, 7);
        assert_eq!(next_id(&mut c, Some(seen)), Ulid::from_parts(9_000, 8));
    }

    #[test]
    fn exhausted_random_moves_to_next_millisecond() {
        let mut c = FixedClock::new(9_000);
        let seen = Ulid::from_parts(9_000, RANDOM_MAX);
        let id = next_id(&mut c, Some(seen));
        assert_eq!(id.time_ms(), 9_001);
        assert!(id > seen);
    }

    #[test]
    fn system_clock_ids_increase() {
        let mut c = SystemClock;
        let mut prev = next_id(&mut c, None);
        for _ in 0..1000 {
            let n = next_id(&mut c, Some(prev));
            assert!(n > prev);
            prev = n;
        }
    }

    #[test]
    fn timestamp_format() {
        assert_eq!(format_ts(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_ts(1_794_054_896_000), "2026-11-07T12:34:56Z");
        assert_eq!(format_ts(951_782_400_000), "2000-02-29T00:00:00Z");
    }
}
