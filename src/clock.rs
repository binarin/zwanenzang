//! The hybrid logical clock behind event ids, the wall clock used for the
//! informational `ts` field, and the local date that relative planning
//! dates resolve against. The clock is a trait so tests can make the wall
//! clock lag or stand still, and fix the time zone.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::planning::Date;
use crate::ulid::{RANDOM_MAX, TIME_MAX, Ulid};

pub trait Clock {
    /// Wall-clock milliseconds since the Unix epoch.
    fn now_ms(&mut self) -> u64;
    /// 80 fresh random bits.
    fn random80(&mut self) -> u128;
    /// The local time zone's offset from UTC, in seconds east, at the
    /// instant `ms` milliseconds after the epoch.
    fn utc_offset_s(&mut self, ms: u64) -> i64;
}

/// Today's date in the clock's local time zone.
pub fn local_today(clock: &mut dyn Clock) -> Date {
    let ms = clock.now_ms();
    let local_s = (ms / 1000) as i64 + clock.utc_offset_s(ms);
    Date::from_days(local_s.div_euclid(86_400))
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

    /// The C library's local time, which follows `TZ` (a zone name or a
    /// POSIX rule such as `UTC-2`) and otherwise the system's zone.
    #[cfg(unix)]
    fn utc_offset_s(&mut self, ms: u64) -> i64 {
        let t = (ms / 1000) as libc::time_t;
        // SAFETY: `localtime_r` only writes the `tm` we own, and reads `t`.
        unsafe {
            let mut tm: libc::tm = std::mem::zeroed();
            if libc::localtime_r(&t, &mut tm).is_null() {
                0
            } else {
                tm.tm_gmtoff as i64
            }
        }
    }

    #[cfg(not(unix))]
    fn utc_offset_s(&mut self, _ms: u64) -> i64 {
        0
    }
}

/// How far an id's time may run ahead of the newest id before it: 1000
/// Gregorian years in milliseconds. No working clock is that far ahead of
/// the last event a tracker saw.
pub const MAX_LEAP_MS: u64 = 1000 * 31_556_952_000;

/// True when `id` is out of range after `anchor`, the newest id seen before
/// it (or the tracker root). Such an id counts neither as accepted nor as
/// seen. Without this bound one line near the end of the ULID range would
/// leave the hybrid clock no later id, and every later write would fail;
/// with it, reaching the end takes a chain of such leaps.
pub fn leaps_too_far(anchor: Ulid, id: Ulid) -> bool {
    id.time_ms() > anchor.time_ms().saturating_add(MAX_LEAP_MS)
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
        // sorting after its parent instead of overflowing. One stray line
        // cannot put the highest seen id there: see `leaps_too_far`.
        Ulid::from_parts((seen_t + 1).min(TIME_MAX), clock.random80())
    }
}

/// Formats milliseconds since the epoch as RFC 3339 UTC with second
/// precision, e.g. `2026-11-07T12:34:56Z`.
pub fn format_ts(ms: u64) -> String {
    let secs = ms / 1000;
    let date = Date::from_days((secs / 86_400) as i64);
    let rem = secs % 86_400;
    format!(
        "{date}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem / 60) % 60,
        rem % 60
    )
}

/// A deterministic clock for tests: a settable wall clock, a counter as
/// the random source and a fixed time zone offset.
#[derive(Debug, Clone)]
pub struct FixedClock {
    pub now: u64,
    pub next_random: u128,
    /// Seconds east of UTC; 0 is UTC.
    pub utc_offset_s: i64,
}

impl FixedClock {
    pub fn new(now: u64) -> FixedClock {
        FixedClock {
            now,
            next_random: 1000,
            utc_offset_s: 0,
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

    fn utc_offset_s(&mut self, _ms: u64) -> i64 {
        self.utc_offset_s
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
    fn leap_bound() {
        let anchor = Ulid::from_parts(1_794_054_896_000, 5);
        let edge = Ulid::from_parts(1_794_054_896_000 + MAX_LEAP_MS, RANDOM_MAX);
        assert!(!leaps_too_far(anchor, edge));
        assert!(leaps_too_far(anchor, Ulid(edge.0 + 1)));
        assert!(leaps_too_far(anchor, Ulid(u128::MAX)));
        // Only leaps ahead are bounded.
        assert!(!leaps_too_far(anchor, Ulid(0)));
        assert!(!leaps_too_far(Ulid(u128::MAX), Ulid(u128::MAX)));
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
    fn local_today_follows_the_offset() {
        // 2026-11-26T23:30:00Z.
        let mut c = FixedClock::new(1_795_735_800_000);
        assert_eq!(format_ts(c.now), "2026-11-26T23:30:00Z");
        assert_eq!(local_today(&mut c).to_string(), "2026-11-26");
        c.utc_offset_s = 3600;
        assert_eq!(local_today(&mut c).to_string(), "2026-11-27");
        c.utc_offset_s = -14 * 3600;
        assert_eq!(local_today(&mut c).to_string(), "2026-11-26");
        c.now = 1_795_660_200_000; // 2026-11-26T02:30:00Z
        assert_eq!(local_today(&mut c).to_string(), "2026-11-25");
    }

    #[test]
    fn timestamp_format() {
        assert_eq!(format_ts(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_ts(1_794_054_896_000), "2026-11-07T12:34:56Z");
        assert_eq!(format_ts(951_782_400_000), "2000-02-29T00:00:00Z");
    }
}
