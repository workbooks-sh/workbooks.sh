//! Pure, host-injected time math for the Work format.
//!
//! "now" is ALWAYS a parameter — this module never reads the system clock, never
//! does I/O, and is fully `wasm32`-clean (no extra crates). The kernel computes
//! *when* things fire; the host's scheduler does the actual firing. See the Time
//! section of docs/WORK-FORMAT.md.
//!
//! Surfaces:
//!   - [`Instant`]  — parse/format ISO-8601 (date and tz-aware date-time), compare.
//!   - [`Duration`] — parse human shorthand ("3d","2h30m","90m") ↔ ISO-8601
//!                    ("P3D","PT2H30M") + total seconds.
//!   - [`Interval`] — start+end → duration.
//!   - recurrence   — "weekly"/"daily" → RRULE; 5-field cron → next fire AFTER a
//!                    given `now` (now is a parameter).
//!   - rollups      — sum a slice of duration strings.

// ── Instant: ISO-8601 date / date-time, timezone-aware ──────────────────────

/// A timezone-aware instant, stored as a count of seconds since the proleptic
/// Gregorian epoch (0000-01-01T00:00:00Z) so two instants are comparable across
/// offsets. Date-only values are treated as midnight UTC.
#[derive(Debug, Clone, Copy)]
pub struct Instant {
    /// Seconds since the Unix epoch, UTC-normalized (offset folded in).
    epoch: i64,
    /// True when the source carried only a date (no time component).
    date_only: bool,
    /// The original UTC offset in minutes (0 for `Z` or date-only), retained so
    /// `format` round-trips the wall-clock the author wrote.
    offset_min: i32,
}

// Identity + ordering are by the UTC instant ONLY: two values denoting the same
// moment in different offsets are equal and neither orders before the other.
impl PartialEq for Instant {
    fn eq(&self, other: &Self) -> bool {
        self.epoch == other.epoch
    }
}
impl Eq for Instant {}
impl PartialOrd for Instant {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Instant {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.epoch.cmp(&other.epoch)
    }
}

impl Instant {
    /// Parse an ISO-8601 date (`2026-06-22`) or date-time
    /// (`2026-06-22T10:00Z`, `2026-06-22T10:00:00+02:00`, `...-05:00`).
    pub fn parse(s: &str) -> Option<Instant> {
        let s = s.trim();
        let (date, rest) = match s.split_once(['T', 't']) {
            Some((d, t)) => (d, Some(t)),
            None => (s, None),
        };
        let (y, mo, d) = parse_ymd(date)?;
        let days = days_from_civil(y, mo, d)?;

        let Some(rest) = rest else {
            return Some(Instant { epoch: days * 86_400, date_only: true, offset_min: 0 });
        };

        // Split the offset (Z | ±HH:MM | ±HHMM) off the time-of-day.
        let (time, offset_min) = split_offset(rest)?;
        let (hh, mm, ss) = parse_hms(time)?;
        if hh > 23 || mm > 59 || ss > 60 {
            return None;
        }
        let local = days * 86_400 + (hh as i64) * 3600 + (mm as i64) * 60 + ss as i64;
        // UTC = local - offset.
        let epoch = local - (offset_min as i64) * 60;
        Some(Instant { epoch, date_only: false, offset_min })
    }

    /// Add a [`Duration`] (calendar-naive: months/years are not modeled — the
    /// shorthand only carries d/h/m/s, all fixed-length).
    pub fn add(&self, dur: &Duration) -> Instant {
        Instant { epoch: self.epoch + dur.secs, date_only: false, offset_min: self.offset_min }
    }

    /// The signed [`Duration`] from `self` to `other` (positive when `other`
    /// is later).
    pub fn diff(&self, other: &Instant) -> Duration {
        Duration { secs: other.epoch - self.epoch }
    }

    /// Format back to ISO-8601 in the instant's original offset. Date-only stays
    /// `YYYY-MM-DD`; `Z` is emitted for a zero offset, else `±HH:MM`.
    pub fn format(&self) -> String {
        let local = self.epoch + (self.offset_min as i64) * 60;
        let days = local.div_euclid(86_400);
        let tod = local.rem_euclid(86_400);
        let (y, mo, d) = civil_from_days(days);
        if self.date_only {
            return format!("{:04}-{:02}-{:02}", y, mo, d);
        }
        let (hh, mm, ss) = ((tod / 3600), (tod % 3600) / 60, tod % 60);
        let off = if self.offset_min == 0 {
            "Z".to_string()
        } else {
            let sign = if self.offset_min < 0 { '-' } else { '+' };
            let abs = self.offset_min.abs();
            format!("{}{:02}:{:02}", sign, abs / 60, abs % 60)
        };
        format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{}", y, mo, d, hh, mm, ss, off)
    }

    /// UTC calendar fields — used by the cron engine (always reasons in UTC).
    fn utc_fields(&self) -> (i64, u32, u32, u32, u32, u32) {
        let days = self.epoch.div_euclid(86_400);
        let tod = self.epoch.rem_euclid(86_400);
        let (y, mo, d) = civil_from_days(days);
        (y, mo, d, (tod / 3600) as u32, ((tod % 3600) / 60) as u32, (tod % 60) as u32)
    }
}

fn parse_ymd(s: &str) -> Option<(i64, u32, u32)> {
    let mut it = s.split('-');
    // A leading '-' (negative year) is not supported; years are >= 0.
    let y: i64 = it.next()?.parse().ok()?;
    let mo: u32 = it.next()?.parse().ok()?;
    let d: u32 = it.next()?.parse().ok()?;
    if it.next().is_some() || mo < 1 || mo > 12 || d < 1 || d > 31 {
        return None;
    }
    Some((y, mo, d))
}

fn parse_hms(s: &str) -> Option<(u32, u32, u32)> {
    let mut it = s.split(':');
    let hh: u32 = it.next()?.parse().ok()?;
    let mm: u32 = it.next()?.parse().ok()?;
    let ss: u32 = match it.next() {
        // Drop any fractional seconds.
        Some(sec) => sec.split('.').next()?.parse().ok()?,
        None => 0,
    };
    if it.next().is_some() {
        return None;
    }
    Some((hh, mm, ss))
}

/// Split a trailing timezone marker off a time string → (time, offset_minutes).
fn split_offset(rest: &str) -> Option<(&str, i32)> {
    if let Some(t) = rest.strip_suffix(['Z', 'z']) {
        return Some((t, 0));
    }
    // Find the sign that begins the offset (after the time digits).
    for (i, c) in rest.char_indices() {
        if (c == '+' || c == '-') && i > 0 {
            let (time, off) = (&rest[..i], &rest[i..]);
            return Some((time, parse_offset(off)?));
        }
    }
    // No offset present → naive, treated as UTC.
    Some((rest, 0))
}

fn parse_offset(s: &str) -> Option<i32> {
    let (sign, rest) = match s.chars().next()? {
        '+' => (1, &s[1..]),
        '-' => (-1, &s[1..]),
        _ => return None,
    };
    let (h, m) = match rest.split_once(':') {
        Some((h, m)) => (h, m),
        None if rest.len() == 4 => (&rest[..2], &rest[2..]),
        None => (rest, "0"),
    };
    let h: i32 = h.parse().ok()?;
    let m: i32 = m.parse().ok()?;
    Some(sign * (h * 60 + m))
}

// Howard Hinnant's civil↔days algorithms — pure integer date math, no clock.
// `days` is days since the Unix epoch (1970-01-01); the absolute anchor is
// irrelevant to this module (everything is differences + a host-injected now),
// but using the canonical, exactly-invertible form keeps the math trustworthy.
fn days_from_civil(y: i64, m: u32, d: u32) -> Option<i64> {
    if m < 1 || m > 12 || d < 1 || d > days_in_month(y, m) {
        return None;
    }
    let yy = if m <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400; // [0, 399]
    let m = m as i64;
    let d = d as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    Some(era * 146_097 + doe - 719_468)
}

fn days_in_month(y: i64, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => if is_leap(y) { 29 } else { 28 },
        _ => 0,
    }
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    // Inverse of days_from_civil: z is days since the Unix epoch.
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// ── Duration: human shorthand ↔ ISO-8601 + total seconds ────────────────────

/// A fixed-length span in seconds. Day = 86400s; weeks/months/years are not
/// part of the shorthand (those belong to recurrence, not durations).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Duration {
    pub secs: i64,
}

impl Duration {
    /// Parse human shorthand: `"3d"`, `"2h30m"`, `"90m"`, `"1d12h"`, `"45s"`,
    /// `"1w"`. Also accepts ISO-8601 (`"P3D"`, `"PT2H30M"`) for round-trips.
    pub fn parse(s: &str) -> Option<Duration> {
        let s = s.trim();
        if s.is_empty() {
            return None;
        }
        if s.starts_with('P') || s.starts_with('p') {
            return Self::parse_iso(s);
        }
        let mut secs: i64 = 0;
        let mut num = String::new();
        let mut saw_unit = false;
        for ch in s.chars() {
            if ch.is_ascii_digit() {
                num.push(ch);
            } else {
                let n: i64 = num.parse().ok()?;
                num.clear();
                secs += n * unit_secs(ch)?;
                saw_unit = true;
            }
        }
        // A trailing bare number with no unit is invalid shorthand.
        if !num.is_empty() || !saw_unit {
            return None;
        }
        Some(Duration { secs })
    }

    /// Parse ISO-8601 duration. Supports the d/h/m/s subset (the only units the
    /// shorthand emits); weeks `W` accepted, calendar Y/M rejected (ambiguous).
    fn parse_iso(s: &str) -> Option<Duration> {
        let body = &s[1..]; // strip leading P
        let (date, time) = match body.split_once(['T', 't']) {
            Some((d, t)) => (d, t),
            None => (body, ""),
        };
        let mut secs = 0i64;
        let mut num = String::new();
        for ch in date.chars() {
            if ch.is_ascii_digit() {
                num.push(ch);
            } else {
                let n: i64 = num.parse().ok()?;
                num.clear();
                secs += n * match ch.to_ascii_uppercase() {
                    'W' => 604_800,
                    'D' => 86_400,
                    _ => return None, // Y/M not representable as fixed seconds
                };
            }
        }
        if !num.is_empty() {
            return None;
        }
        for ch in time.chars() {
            if ch.is_ascii_digit() {
                num.push(ch);
            } else {
                let n: i64 = num.parse().ok()?;
                num.clear();
                secs += n * match ch.to_ascii_uppercase() {
                    'H' => 3600,
                    'M' => 60,
                    'S' => 1,
                    _ => return None,
                };
            }
        }
        if !num.is_empty() {
            return None;
        }
        Some(Duration { secs })
    }

    pub fn total_seconds(&self) -> i64 {
        self.secs
    }

    /// Format as normalized ISO-8601: `P[nD]T[nH][nM][nS]`. Days roll up from
    /// seconds; sub-day remainder goes in the time part. `PT0S` for zero.
    pub fn to_iso(&self) -> String {
        let neg = self.secs < 0;
        let mut s = self.secs.abs();
        let days = s / 86_400;
        s %= 86_400;
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
        let mut out = String::new();
        if neg {
            out.push('-');
        }
        out.push('P');
        if days > 0 {
            out.push_str(&format!("{}D", days));
        }
        if h > 0 || m > 0 || sec > 0 || days == 0 {
            out.push('T');
            if h > 0 {
                out.push_str(&format!("{}H", h));
            }
            if m > 0 {
                out.push_str(&format!("{}M", m));
            }
            // Emit seconds when nonzero, or when nothing else was emitted (PT0S).
            if sec > 0 || (h == 0 && m == 0) {
                out.push_str(&format!("{}S", sec));
            }
        }
        out
    }
}

fn unit_secs(u: char) -> Option<i64> {
    match u {
        'w' | 'W' => Some(604_800),
        'd' | 'D' => Some(86_400),
        'h' | 'H' => Some(3600),
        'm' => Some(60),
        's' => Some(1),
        _ => None,
    }
}

// ── Interval ────────────────────────────────────────────────────────────────

/// A half-open span between two instants.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Interval {
    pub start: Instant,
    pub end: Instant,
}

impl Interval {
    pub fn parse(start: &str, end: &str) -> Option<Interval> {
        Some(Interval { start: Instant::parse(start)?, end: Instant::parse(end)? })
    }

    pub fn duration(&self) -> Duration {
        self.start.diff(&self.end)
    }
}

// ── Recurrence ──────────────────────────────────────────────────────────────

/// Normalize a simple cadence keyword to an RRULE-style string. Unknown
/// keywords return `None`.
pub fn repeat_to_rrule(repeat: &str) -> Option<String> {
    let freq = match repeat.trim().to_ascii_lowercase().as_str() {
        "daily" => "DAILY",
        "weekly" => "WEEKLY",
        "monthly" => "MONTHLY",
        "yearly" | "annually" => "YEARLY",
        "hourly" => "HOURLY",
        _ => return None,
    };
    Some(format!("FREQ={}", freq))
}

/// A parsed 5-field cron expression: `minute hour day-of-month month day-of-week`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cron {
    min: Vec<u32>,
    hour: Vec<u32>,
    dom: Vec<u32>,
    mon: Vec<u32>,
    dow: Vec<u32>, // 0..=6, Sunday = 0
    /// True when both day-of-month and day-of-week are restricted (cron OR-joins
    /// them in that case, per Vixie cron).
    dom_dow_restricted: bool,
}

impl Cron {
    /// Parse a standard 5-field cron expression. Supports `*`, ranges `a-b`,
    /// lists `a,b,c`, and steps `*/n` / `a-b/n`.
    pub fn parse(expr: &str) -> Option<Cron> {
        let f: Vec<&str> = expr.split_whitespace().collect();
        if f.len() != 5 {
            return None;
        }
        let min = parse_field(f[0], 0, 59)?;
        let hour = parse_field(f[1], 0, 23)?;
        let dom = parse_field(f[2], 1, 31)?;
        let mon = parse_field(f[3], 1, 12)?;
        // Accept 0 or 7 for Sunday; normalize 7 → 0.
        let mut dow = parse_field(f[4], 0, 7)?;
        for v in dow.iter_mut() {
            if *v == 7 {
                *v = 0;
            }
        }
        dow.sort_unstable();
        dow.dedup();
        let dom_dow_restricted = f[2] != "*" && f[4] != "*";
        Some(Cron { min, hour, dom, mon, dow, dom_dow_restricted })
    }

    /// The first fire time strictly AFTER `now`. `now` is a parameter — the
    /// clock is never read. Searches minute-by-minute over a bounded horizon
    /// (~4 years) so an unsatisfiable schedule terminates with `None`.
    pub fn next_after(&self, now: &Instant) -> Option<Instant> {
        // Start at the next whole minute strictly after `now`.
        let start = (now.epoch / 60 + 1) * 60;
        let mut cur = Instant { epoch: start, date_only: false, offset_min: 0 };
        // Horizon: minutes in ~4 years (covers Feb-29 + any cron in range).
        let limit = 4 * 366 * 24 * 60;
        for _ in 0..limit {
            let (_, mo, d, hh, mm, _) = cur.utc_fields();
            let dow = day_of_week(cur.epoch);
            if self.min.contains(&mm)
                && self.hour.contains(&hh)
                && self.mon.contains(&mo)
                && self.day_matches(d, dow)
            {
                return Some(cur);
            }
            cur.epoch += 60;
        }
        None
    }

    fn day_matches(&self, dom: u32, dow: u32) -> bool {
        if self.dom_dow_restricted {
            // Vixie cron: when both restricted, a match on EITHER fires.
            self.dom.contains(&dom) || self.dow.contains(&dow)
        } else {
            self.dom.contains(&dom) && self.dow.contains(&dow)
        }
    }
}

/// Day of week for an epoch (seconds since the Unix epoch). 1970-01-01 was a
/// Thursday (= 4 with Sunday = 0), the cron day-of-week convention.
fn day_of_week(epoch: i64) -> u32 {
    let days = epoch.div_euclid(86_400);
    ((days.rem_euclid(7) + 4).rem_euclid(7)) as u32
}

/// Parse one cron field into the explicit set of matching values.
fn parse_field(f: &str, lo: u32, hi: u32) -> Option<Vec<u32>> {
    let mut out = vec![];
    for part in f.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => (r, s.parse::<u32>().ok().filter(|n| *n > 0)?),
            None => (part, 1),
        };
        let (start, end) = if range == "*" {
            (lo, hi)
        } else if let Some((a, b)) = range.split_once('-') {
            (a.parse().ok()?, b.parse().ok()?)
        } else {
            let v: u32 = range.parse().ok()?;
            (v, v)
        };
        if start < lo || end > hi || start > end {
            return None;
        }
        let mut v = start;
        while v <= end {
            out.push(v);
            v += step;
        }
    }
    out.sort_unstable();
    out.dedup();
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

// ── Rollups ─────────────────────────────────────────────────────────────────

/// Sum a slice of duration strings → total [`Duration`]. Unparseable entries
/// are skipped (a rollup of `work-task` estimates should not fail on one blank
/// or malformed estimate).
pub fn sum_durations<S: AsRef<str>>(durs: &[S]) -> Duration {
    let secs = durs
        .iter()
        .filter_map(|d| Duration::parse(d.as_ref()))
        .map(|d| d.secs)
        .sum();
    Duration { secs }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Instant ──
    #[test]
    fn instant_date_only_roundtrip() {
        let i = Instant::parse("2026-06-22").unwrap();
        assert!(i.date_only);
        assert_eq!(i.format(), "2026-06-22");
    }

    #[test]
    fn instant_datetime_z_roundtrip() {
        let i = Instant::parse("2026-06-22T10:00Z").unwrap();
        assert_eq!(i.format(), "2026-06-22T10:00:00Z");
    }

    #[test]
    fn instant_offset_roundtrip_and_normalize() {
        let i = Instant::parse("2026-06-22T10:00:00+02:00").unwrap();
        // Round-trips the wall clock + offset.
        assert_eq!(i.format(), "2026-06-22T10:00:00+02:00");
        // 10:00+02:00 == 08:00Z → same UTC instant, comparable across offsets.
        let z = Instant::parse("2026-06-22T08:00:00Z").unwrap();
        assert_eq!(i.epoch, z.epoch);
        assert_eq!(i, z); // equality is by the UTC instant, ignoring offset
        assert!(!(i < z) && !(z < i));
    }

    #[test]
    fn instant_compare() {
        let a = Instant::parse("2026-06-22").unwrap();
        let b = Instant::parse("2026-06-23").unwrap();
        assert!(a < b);
    }

    #[test]
    fn instant_add_and_diff() {
        let a = Instant::parse("2026-06-22T00:00:00Z").unwrap();
        let later = a.add(&Duration::parse("2h30m").unwrap());
        assert_eq!(later.format(), "2026-06-22T02:30:00Z");
        let d = a.diff(&later);
        assert_eq!(d.total_seconds(), 9000);
    }

    #[test]
    fn instant_rejects_garbage() {
        assert!(Instant::parse("nope").is_none());
        assert!(Instant::parse("2026-13-01").is_none());
        assert!(Instant::parse("2026-02-30").is_none());
    }

    #[test]
    fn civil_days_roundtrip_known_dates() {
        for (s, _) in [("2026-06-22", ()), ("2000-01-01", ()), ("1970-01-01", ())] {
            let i = Instant::parse(s).unwrap();
            assert_eq!(i.format(), s, "roundtrip {}", s);
        }
    }

    #[test]
    fn leap_day_valid_and_dow() {
        let i = Instant::parse("2024-02-29").unwrap();
        assert_eq!(i.format(), "2024-02-29");
        // 2024-02-29 is a Thursday → dow 4.
        assert_eq!(day_of_week(i.epoch), 4);
    }

    // ── Duration ──
    #[test]
    fn duration_shorthand_to_iso() {
        assert_eq!(Duration::parse("3d").unwrap().to_iso(), "P3D");
        assert_eq!(Duration::parse("2h30m").unwrap().to_iso(), "PT2H30M");
        assert_eq!(Duration::parse("90m").unwrap().to_iso(), "PT1H30M");
        assert_eq!(Duration::parse("1d12h").unwrap().to_iso(), "P1DT12H");
        assert_eq!(Duration::parse("45s").unwrap().to_iso(), "PT45S");
        assert_eq!(Duration::parse("1w").unwrap().to_iso(), "P7D");
    }

    #[test]
    fn duration_total_seconds() {
        assert_eq!(Duration::parse("2h30m").unwrap().total_seconds(), 9000);
        assert_eq!(Duration::parse("90m").unwrap().total_seconds(), 5400);
        assert_eq!(Duration::parse("3d").unwrap().total_seconds(), 259_200);
    }

    #[test]
    fn duration_iso_roundtrip() {
        for s in ["P3D", "PT2H30M", "PT1H30M", "P1DT12H", "PT45S", "PT0S"] {
            let d = Duration::parse(s).unwrap();
            assert_eq!(d.to_iso(), s, "iso roundtrip {}", s);
        }
    }

    #[test]
    fn duration_zero() {
        assert_eq!(Duration { secs: 0 }.to_iso(), "PT0S");
    }

    #[test]
    fn duration_rejects_garbage() {
        assert!(Duration::parse("").is_none());
        assert!(Duration::parse("3").is_none()); // no unit
        assert!(Duration::parse("3x").is_none()); // bad unit
        assert!(Duration::parse("PT3Y").is_none()); // calendar unit in iso
    }

    // ── Interval ──
    #[test]
    fn interval_duration() {
        let iv = Interval::parse("2026-06-22T09:00Z", "2026-06-22T17:30Z").unwrap();
        assert_eq!(iv.duration().to_iso(), "PT8H30M");
    }

    // ── Recurrence ──
    #[test]
    fn repeat_normalizes() {
        assert_eq!(repeat_to_rrule("weekly").unwrap(), "FREQ=WEEKLY");
        assert_eq!(repeat_to_rrule("Daily").unwrap(), "FREQ=DAILY");
        assert!(repeat_to_rrule("fortnightly").is_none());
    }

    #[test]
    fn cron_next_after_simple() {
        // 0 9 * * 1 = 09:00 every Monday.
        let c = Cron::parse("0 9 * * 1").unwrap();
        // Sunday 2026-06-21 → next is Monday 2026-06-22 09:00Z.
        let now = Instant::parse("2026-06-21T12:00:00Z").unwrap();
        let next = c.next_after(&now).unwrap();
        assert_eq!(next.format(), "2026-06-22T09:00:00Z");
        assert_eq!(day_of_week(next.epoch), 1);
    }

    #[test]
    fn cron_next_after_is_strict() {
        // Already exactly on a fire minute → returns the NEXT one, not now.
        let c = Cron::parse("0 9 * * *").unwrap();
        let now = Instant::parse("2026-06-22T09:00:00Z").unwrap();
        let next = c.next_after(&now).unwrap();
        assert_eq!(next.format(), "2026-06-23T09:00:00Z");
    }

    #[test]
    fn cron_step_and_range() {
        // every 15 min, business hours, weekdays.
        let c = Cron::parse("*/15 9-17 * * 1-5").unwrap();
        let now = Instant::parse("2026-06-22T09:05:00Z").unwrap(); // Monday
        let next = c.next_after(&now).unwrap();
        assert_eq!(next.format(), "2026-06-22T09:15:00Z");
    }

    #[test]
    fn cron_day_of_month() {
        // 1st of every month at midnight.
        let c = Cron::parse("0 0 1 * *").unwrap();
        let now = Instant::parse("2026-06-15T00:00:00Z").unwrap();
        let next = c.next_after(&now).unwrap();
        assert_eq!(next.format(), "2026-07-01T00:00:00Z");
    }

    #[test]
    fn cron_rejects_bad() {
        assert!(Cron::parse("0 9 * *").is_none()); // 4 fields
        assert!(Cron::parse("60 9 * * *").is_none()); // minute out of range
        assert!(Cron::parse("* 24 * * *").is_none()); // hour out of range
    }

    // ── Rollups ──
    #[test]
    fn rollup_sums_estimates() {
        let est = ["3d", "2h30m", "90m"];
        let total = sum_durations(&est);
        // 3d + 2h30m + 1h30m = 259200 + 9000 + 5400 = 273600s
        assert_eq!(total.total_seconds(), 273_600);
        assert_eq!(total.to_iso(), "P3DT4H");
    }

    #[test]
    fn rollup_skips_malformed() {
        let est = ["3d", "", "garbage", "2h"];
        let total = sum_durations(&est);
        assert_eq!(total.total_seconds(), 259_200 + 7200);
    }
}
