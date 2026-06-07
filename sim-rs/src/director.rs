//! Market director. Port of sim/director.lua (docs/01-game-design.md §2/§7).
//!
//! A seeded WEIGHTED EVENT TABLE on a drama curve — not a reactive AI. 1-2
//! telegraphed events per flight: CPM spikes/dips (tax/opportunity), competitor
//! entry (mute), viral moments (amplify), metric blackouts (hide). THE LAW:
//! events amplify, mute, hide, or tax — every effect is a bounded positive
//! multiplier (x1000) or a display flag, so no event can flip a Layer-1 sign,
//! and equal application preserves ad ordering: the lesson survives the storm.
//!
//! Placement: never day 1, weighted days 2-4, telegraphed ahead of the event.
//! Determinism: rng call order matches the Lua exactly; no floats in the
//! deterministic path (the Lua's `floor(ticks_per_day*0.8)` is integer
//! `ticks_per_day*8/10`, cross-validated vs luajit in the goldens below).
use crate::rng::Rng;

/// Bounded effect payload. `None` == the Lua `nil` (absent key).
/// Multipliers are x1000; aspect/metric are display tags.
#[derive(Clone, Debug, PartialEq)]
pub struct Fx {
    pub cpm_x1000: Option<i64>,
    pub hook_x1000: Option<i64>,
    pub amplify_x1000: Option<i64>,
    pub amplify_aspect: Option<&'static str>,
    pub hidden_metric: Option<&'static str>,
}

impl Fx {
    const fn empty() -> Fx {
        Fx { cpm_x1000: None, hook_x1000: None, amplify_x1000: None, amplify_aspect: None, hidden_metric: None }
    }
}

struct TableEntry {
    kind: &'static str,
    weight: i64,
    dur: i64,
    fx: Fx,
}

// kind, weight, duration in ticks, effect payload (bounded multipliers x1000)
const TABLE: [TableEntry; 5] = [
    TableEntry { kind: "cpm_spike", weight: 30, dur: 360,
        fx: Fx { cpm_x1000: Some(1350), ..Fx::empty() } },
    TableEntry { kind: "cpm_dip", weight: 15, dur: 270,
        fx: Fx { cpm_x1000: Some(800), ..Fx::empty() } },
    TableEntry { kind: "competitor_entry", weight: 25, dur: 450,
        fx: Fx { hook_x1000: Some(780), ..Fx::empty() } },
    TableEntry { kind: "viral_moment", weight: 20, dur: 270,
        fx: Fx { amplify_x1000: Some(1500), amplify_aspect: Some("novelty"), ..Fx::empty() } },
    TableEntry { kind: "metrics_blackout", weight: 10, dur: 180,
        fx: Fx { hidden_metric: Some("CVR"), ..Fx::empty() } },
];

// drama curve: start-day weights (day 1 = 0: never)
const DAY_WEIGHTS: [i64; 5] = [0, 30, 40, 25, 5];
const TELEGRAPH_GAP: i64 = 72; // ticks (7.2s warning)

#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub kind: &'static str,
    pub fx: Fx,
    pub telegraph_tick: i64,
    pub start_tick: i64,
    pub end_tick: i64,
}

pub struct Schedule {
    pub events: Vec<Event>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FeedItem {
    pub phase: &'static str,
    pub kind: &'static str,
    pub tick: i64,
}

/// Returns the chosen 0-based index. One next_u32 draw (matches the Lua).
fn weighted_pick(rng: &mut Rng, weights: &[i64]) -> usize {
    let total: i64 = weights.iter().sum();
    let roll = (rng.next_u32() as i64) % total;
    let mut acc = 0i64;
    for (i, &w) in weights.iter().enumerate() {
        acc += w;
        if roll < acc {
            return i;
        }
    }
    weights.len() - 1
}

fn place_event(
    rng: &mut Rng,
    entry: &TableEntry,
    ticks: i64,
    ticks_per_day: i64,
    taken: &[Event],
) -> Option<(i64, i64)> {
    for _ in 0..20 {
        // bounded deterministic retry against overlaps
        let num_days = ticks / ticks_per_day; // floor (positive)
        let mut day_weights: Vec<i64> = Vec::with_capacity(num_days as usize);
        for d in 1..=num_days {
            let w = if d >= 1 && (d as usize) <= DAY_WEIGHTS.len() {
                DAY_WEIGHTS[(d - 1) as usize]
            } else {
                0
            };
            day_weights.push(w);
        }
        let slot_idx = weighted_pick(rng, &day_weights);
        let slot_day = (slot_idx as i64) + 1; // days array is 1..num_days
        // start somewhere in that day's first 80% so end fits comfortably
        let day_start = (slot_day - 1) * ticks_per_day;
        let jitter = (rng.next_u32() as i64) % ((ticks_per_day * 8) / 10);
        let start_tick = day_start + 1 + jitter;
        let end_tick = start_tick + entry.dur;
        if end_tick <= ticks && start_tick > ticks_per_day {
            let mut ok = true;
            for ev in taken {
                if !(end_tick < ev.start_tick || start_tick > ev.end_tick) {
                    ok = false;
                }
            }
            if ok {
                return Some((start_tick, end_tick));
            }
        }
    }
    None
}

pub fn new_schedule(seed: u32, wave: u32, ticks: i64, ticks_per_day: i64) -> Schedule {
    let mut rng = Rng::substream(seed, &format!("director:wave{}", wave));
    let n = 1 + rng.next_u32() % 2; // 1 or 2 events
    let mut events: Vec<Event> = Vec::new();
    let weights: Vec<i64> = TABLE.iter().map(|e| e.weight).collect();
    for _ in 0..n {
        let idx = weighted_pick(&mut rng, &weights);
        let entry = &TABLE[idx];
        if let Some((start_tick, end_tick)) = place_event(&mut rng, entry, ticks, ticks_per_day, &events) {
            events.push(Event {
                kind: entry.kind,
                fx: entry.fx.clone(),
                telegraph_tick: start_tick - TELEGRAPH_GAP,
                start_tick,
                end_tick,
            });
        }
    }
    // chronological order for the feed (start_ticks are distinct: overlaps are rejected)
    events.sort_by(|a, b| a.start_tick.cmp(&b.start_tick));
    Schedule { events }
}

/// Effects active at a tick. Neutral baseline; events overlay their payloads.
pub fn active_effects(schedule: &Schedule, tick: i64) -> Fx {
    let mut fx = Fx { cpm_x1000: Some(1000), hook_x1000: Some(1000), ..Fx::empty() };
    for e in &schedule.events {
        if tick >= e.start_tick && tick <= e.end_tick {
            if let Some(v) = e.fx.cpm_x1000 {
                fx.cpm_x1000 = Some(v);
            }
            if let Some(v) = e.fx.hook_x1000 {
                fx.hook_x1000 = Some(v);
            }
            if let Some(v) = e.fx.amplify_x1000 {
                fx.amplify_x1000 = Some(v);
                fx.amplify_aspect = e.fx.amplify_aspect;
            }
            if let Some(m) = e.fx.hidden_metric {
                fx.hidden_metric = Some(m);
            }
        }
    }
    fx
}

/// UI feed: telegraph/start/end phases crossing [t0, t1].
pub fn events_between(schedule: &Schedule, t0: i64, t1: i64) -> Vec<FeedItem> {
    let mut out = Vec::new();
    for e in &schedule.events {
        if e.telegraph_tick >= t0 && e.telegraph_tick <= t1 {
            out.push(FeedItem { phase: "telegraph", kind: e.kind, tick: e.telegraph_tick });
        }
        if e.start_tick >= t0 && e.start_tick <= t1 {
            out.push(FeedItem { phase: "start", kind: e.kind, tick: e.start_tick });
        }
        if e.end_tick >= t0 && e.end_tick <= t1 {
            out.push(FeedItem { phase: "end", kind: e.kind, tick: e.end_tick });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // ticks=1800, ticks_per_day=360 are the real game values (sim/game.lua).
    fn sched(seed: u32, wave: u32) -> Schedule {
        new_schedule(seed, wave, 1800, 360)
    }

    // Compact (kind, telegraph, start, end) view for golden comparison.
    fn shape(s: &Schedule) -> Vec<(&'static str, i64, i64, i64)> {
        s.events
            .iter()
            .map(|e| (e.kind, e.telegraph_tick, e.start_tick, e.end_tick))
            .collect()
    }

    // Goldens emitted by luajit on sim/director.lua (cross-validated byte-for-byte).
    #[test]
    fn new_schedule_matches_luajit() {
        assert_eq!(shape(&sched(123, 1)), vec![("cpm_spike", 478, 550, 910)]);
        assert_eq!(shape(&sched(123, 2)), vec![("cpm_spike", 1268, 1340, 1700)]);
        assert_eq!(shape(&sched(42, 1)), vec![("cpm_spike", 1070, 1142, 1502)]);
        assert_eq!(
            shape(&sched(7, 3)),
            vec![
                ("competitor_entry", 325, 397, 847),
                ("competitor_entry", 783, 855, 1305),
            ]
        );
        assert_eq!(shape(&sched(999, 5)), vec![("viral_moment", 519, 591, 861)]);
        // two distinct kinds, sorted by start_tick
        assert_eq!(
            shape(&sched(1, 1)),
            vec![
                ("competitor_entry", 730, 802, 1252),
                ("cpm_dip", 1214, 1286, 1556),
            ]
        );
        assert_eq!(
            shape(&sched(1, 5)),
            vec![
                ("cpm_spike", 346, 418, 778),
                ("metrics_blackout", 1030, 1102, 1282),
            ]
        );
    }

    #[test]
    fn fx_payloads_match_luajit() {
        // each kind carries the exact bounded payload from the Lua TABLE
        let cpm = &sched(123, 1).events[0].fx;
        assert_eq!(cpm.cpm_x1000, Some(1350));
        let dip = &sched(1, 1).events[1].fx;
        assert_eq!(dip.cpm_x1000, Some(800));
        let comp = &sched(7, 3).events[0].fx;
        assert_eq!(comp.hook_x1000, Some(780));
        let viral = &sched(999, 5).events[0].fx;
        assert_eq!((viral.amplify_x1000, viral.amplify_aspect), (Some(1500), Some("novelty")));
        let blk = &sched(1, 5).events[1].fx;
        assert_eq!(blk.hidden_metric, Some("CVR"));
    }

    #[test]
    fn active_effects_matches_luajit() {
        let s = sched(42, 1); // cpm_spike 1142..1502
        let base = active_effects(&s, 1000);
        assert_eq!((base.cpm_x1000, base.hook_x1000), (Some(1000), Some(1000)));
        assert_eq!(base.amplify_x1000, None);
        let inside = active_effects(&s, 1500);
        assert_eq!(inside.cpm_x1000, Some(1350));
        assert_eq!(inside.hook_x1000, Some(1000));

        let amp = active_effects(&sched(999, 5), 700); // viral 591..861
        assert_eq!((amp.amplify_x1000, amp.amplify_aspect), (Some(1500), Some("novelty")));

        let blk = active_effects(&sched(1, 5), 1200); // blackout 1102..1282
        assert_eq!(blk.hidden_metric, Some("CVR"));
    }

    #[test]
    fn events_between_matches_luajit() {
        let s = sched(42, 1); // single cpm_spike: tel=1070 start=1142 end=1502
        let full = events_between(&s, 0, 1800);
        assert_eq!(
            full,
            vec![
                FeedItem { phase: "telegraph", kind: "cpm_spike", tick: 1070 },
                FeedItem { phase: "start", kind: "cpm_spike", tick: 1142 },
                FeedItem { phase: "end", kind: "cpm_spike", tick: 1502 },
            ]
        );
        let bound = events_between(&s, 1100, 1200);
        assert_eq!(
            bound,
            vec![FeedItem { phase: "start", kind: "cpm_spike", tick: 1142 }]
        );
    }
}
