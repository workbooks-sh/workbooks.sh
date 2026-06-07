//! Resonance/aspect system. Faithful port of sim/resonance.lua.
//!
//! Cards carry typed aspect tags; an ad's SUMMED aspect vector is scored against
//! a lane's hidden weights. Two layers:
//!   LAYER 1 — global truths, never randomized: sign classes per
//!             (aspect x Schwartz stage x metric). The curriculum. Signs NEVER flip.
//!   LAYER 2 — seeded per (run, client): magnitude multipliers (x1000 ints,
//!             500..1500) and sparse pair quirks bounded so they can never flip
//!             a Layer-1 sign.
//!
//! Output: integer ppm DELTAS consumed by funnel via apply().
//! Determinism: integer math only (see notes below on why i64 division matches
//! the Lua `trunc(.../1000)`), canonical ASPECTS order, named rng substreams.
//! rng call order/count in new_lane is load-bearing — do NOT reorder.
//!
//! WHY i64 DIVISION == LUA `trunc(x/1000)`:
//!   The Lua numerators are exact integers well within 2^53, so `N/1000` (a
//!   double) lands within < 1 ULP of the true rational. The fractional part is
//!   a multiple of 1/1000, i.e. at least 0.001 from any integer, while the ULP
//!   at our magnitudes (|N| << 4.5e12) is far below 0.001 — so `trunc(N/1000.0)`
//!   never crosses an integer boundary and equals i64 truncating division.
//!   `def.fat * pts / 10`: fat is always a multiple of 100, so the term is an
//!   exact integer; the running sum is integer and `math.floor` is identity.
use crate::rng::Rng;

pub const STAGES: [&str; 5] = ["UNAWARE", "PROBLEM", "SOLUTION", "PRODUCT", "MOST_AWARE"];

pub const ASPECTS: [&str; 10] = [
    "problem", "solution", "mechanism", "comparison", "social_proof",
    "trust", "urgency", "scarcity", "offer_strength", "novelty",
];

/// metric index: 0=hook, 1=ctr|stop, 2=cvr (mirrors Lua METRIC_KEYS order).
pub const METRIC_KEYS: [&str; 3] = ["hook", "ctr", "cvr"];

// ppm per (class-unit x aspect-point) before Layer-2 scaling, per metric.
const UNIT: [i64; 3] = [4000, 1500, 800];
const CLAMP: [i64; 3] = [120000, 40000, 15000];
const N_COMBOS: usize = 3;

/// LAYER 1: sign classes (-2..+2) per stage position, per metric; plus extra
/// fatigue rate per aspect point (x1000, baseline accrual handled in score).
/// THE LAW: these signs are global truths and must NEVER flip.
struct L1Entry {
    hook: [i64; 5],
    ctr: [i64; 5],
    cvr: [i64; 5],
    fat: i64,
}

// Indexed by aspect position (same order as ASPECTS).
const L1: [L1Entry; 10] = [
    // problem
    L1Entry { hook: [2, 2, 1, 0, 0], ctr: [1, 1, 0, 0, 0], cvr: [0, 0, 0, 0, 0], fat: 0 },
    // solution
    L1Entry { hook: [1, 2, 2, 1, 0], ctr: [0, 1, 2, 1, 0], cvr: [0, 0, 1, 0, 0], fat: 0 },
    // mechanism
    L1Entry { hook: [0, 1, 2, 1, 0], ctr: [0, 0, 2, 1, 0], cvr: [0, 0, 1, 1, 0], fat: 0 },
    // comparison
    L1Entry { hook: [0, 0, 1, 2, 1], ctr: [0, 0, 1, 2, 1], cvr: [0, 0, 0, 1, 1], fat: 0 },
    // social_proof
    L1Entry { hook: [0, 0, 1, 2, 2], ctr: [0, 0, 0, 1, 2], cvr: [0, 0, 1, 1, 2], fat: 0 },
    // trust
    L1Entry { hook: [0, 0, 0, 1, 1], ctr: [0, 0, 0, 1, 1], cvr: [1, 1, 1, 2, 2], fat: 0 },
    // urgency
    L1Entry { hook: [1, 1, 1, 1, 1], ctr: [2, 2, 2, 2, 2], cvr: [-1, 0, 0, 0, 1], fat: 500 },
    // scarcity
    L1Entry { hook: [0, 1, 1, 1, 1], ctr: [1, 1, 1, 2, 2], cvr: [0, 0, 0, 0, 1], fat: 300 },
    // offer_strength
    L1Entry { hook: [0, 0, 0, 1, 1], ctr: [0, 0, 1, 1, 2], cvr: [1, 1, 1, 2, 2], fat: 0 },
    // novelty
    L1Entry { hook: [2, 1, 1, 1, 0], ctr: [1, 1, 0, 0, 0], cvr: [0, 0, 0, 0, 0], fat: 200 },
];

/// Position (1-based) of a stage in STAGES; mirrors Lua STAGE_IDX. None if unknown.
pub fn stage_index(name: &str) -> Option<usize> {
    STAGES.iter().position(|s| *s == name).map(|i| i + 1)
}

/// Position (0-based) of an aspect in ASPECTS. None if unknown.
pub fn aspect_index(name: &str) -> Option<usize> {
    ASPECTS.iter().position(|a| *a == name)
}

/// Expose Layer-1 class for tests / the CI sign-invariance check.
/// metric_index: 1=hook, 2=ctr|stop, 3=cvr (1-based, mirrors the Lua signature).
pub fn layer1_class(aspect: &str, stage: &str, metric_index: usize) -> i64 {
    let ai = aspect_index(aspect).unwrap_or_else(|| panic!("unknown aspect {}", aspect));
    let si = stage_index(stage).unwrap_or_else(|| panic!("unknown stage {}", stage)) - 1;
    let def = &L1[ai];
    let arr = match metric_index {
        1 => &def.hook,
        2 => &def.ctr,
        3 => &def.cvr,
        _ => panic!("bad metric_index {}", metric_index),
    };
    arr[si]
}

/// Sparse pair quirk: bonus per shared (min) point on `metric` when both
/// aspects `a` and `b` are present. a/b are 1-based aspect indices (mirrors Lua).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Combo {
    pub a: usize,        // 1-based aspect index
    pub b: usize,        // 1-based aspect index, b != a, a < b
    pub metric: usize,   // 0=hook,1=ctr,2=cvr (index into METRIC_KEYS)
    pub bonus: i64,      // x1000 per min-point, -300..+600
}

/// Hidden weights for one (run seed, client, stage). stage_idx is 1-based.
#[derive(Clone)]
pub struct Lane {
    pub stage_idx: usize,    // 1-based position in STAGES
    pub mults: [i64; 10],    // x1000 magnitude multipliers, 500..1500
    pub combos: Vec<Combo>,
}

/// LAYER 2: lane = hidden weights for one (run seed, client, stage).
/// rng draw order: 10 mults, then per combo (a, b, [retries on b==a], metric, bonus).
pub fn new_lane(seed: u32, client: &str, stage: &str) -> Lane {
    let stage_idx = stage_index(stage).unwrap_or_else(|| panic!("unknown stage {}", stage));
    let mut rng = Rng::substream(seed, &format!("resonance:{}:{}", client, stage));
    let mut mults = [0i64; 10];
    for m in mults.iter_mut() {
        *m = 500 + (rng.next_u32() % 1001) as i64; // x1000: 0.5x .. 1.5x, sign-preserving
    }
    let mut combos: Vec<Combo> = Vec::with_capacity(N_COMBOS);
    for _ in 0..N_COMBOS {
        let mut a = 1 + (rng.next_u32() % 10) as usize;
        let mut b = 1 + (rng.next_u32() % 10) as usize;
        while b == a {
            b = 1 + (rng.next_u32() % 10) as usize;
        }
        if a > b {
            std::mem::swap(&mut a, &mut b);
        }
        let metric = (rng.next_u32() % 3) as usize;
        // x1000 bonus per min-point: -300..+600. Bounded below a single-aspect
        // contribution so a quirk can never flip THE LAW.
        let bonus = (rng.next_u32() % 901) as i64 - 300;
        combos.push(Combo { a, b, metric, bonus });
    }
    Lane { stage_idx, mults, combos }
}

/// Build a canonical aspect-point vector from (name, points) pairs.
/// Unknown aspect names are ignored (mirrors `vector[name]` over a sparse table).
pub fn vector(pairs: &[(&str, i64)]) -> [i64; 10] {
    let mut v = [0i64; 10];
    for (name, pts) in pairs {
        if let Some(i) = aspect_index(name) {
            v[i] = *pts;
        }
    }
    v
}

/// Integer ppm deltas + fatigue, the table returned by Resonance.score.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mods {
    pub hook_ppm_delta: i64,
    pub click_given_stop_ppm_delta: i64,
    pub cvr_ppm_delta: i64,
    pub fatigue_rate_x1000: i64,
}

/// Score an ad's summed aspect vector against a lane -> integer ppm deltas.
/// `vector` is in canonical ASPECTS order (build via `vector(...)`); non-positive
/// entries contribute nothing.
pub fn score(lane: &Lane, vector: &[i64; 10]) -> Mods {
    let mut deltas = [0i64; 3]; // hook, ctr, cvr
    let mut fatigue: i64 = 1000;

    for i in 0..ASPECTS.len() {
        let pts = vector[i];
        if pts > 0 {
            let def = &L1[i];
            let arrs: [&[i64; 5]; 3] = [&def.hook, &def.ctr, &def.cvr];
            for mk in 0..3 {
                let class = arrs[mk][lane.stage_idx - 1];
                if class != 0 {
                    deltas[mk] += class * pts * UNIT[mk] * lane.mults[i] / 1000;
                }
            }
            fatigue += def.fat * pts / 10; // fat is x1000 per 10 points
        }
    }

    for c in &lane.combos {
        let pa = vector[c.a - 1];
        let pb = vector[c.b - 1];
        let m = if pa < pb { pa } else { pb };
        if m > 0 {
            deltas[c.metric] += m * UNIT[c.metric] * c.bonus / 1000;
        }
    }

    for mk in 0..3 {
        if deltas[mk] > CLAMP[mk] {
            deltas[mk] = CLAMP[mk];
        }
        if deltas[mk] < -CLAMP[mk] {
            deltas[mk] = -CLAMP[mk];
        }
    }

    Mods {
        hook_ppm_delta: deltas[0],
        click_given_stop_ppm_delta: deltas[1],
        cvr_ppm_delta: deltas[2],
        fatigue_rate_x1000: fatigue,
    }
}

/// Funnel-truth-shaped input to apply. resonance.lua treats `base` as a
/// duck-typed funnel truth and requires only sim.rng, so this module keeps that
/// independence (the integrate phase bridges to sim::funnel::Truth if needed).
#[derive(Clone, Copy)]
pub struct BaseTruth {
    pub hook_ppm: u32,
    pub hold_given_stop_ppm: Option<u32>,
    pub click_given_stop_ppm: u32,
    pub cvr_ppm: u32,
    pub aov_cents: u64,
}

/// Funnel truth merged with resonance deltas + the resolved fatigue rate.
#[derive(Clone, Copy)]
pub struct AppliedTruth {
    pub hook_ppm: u32,
    pub hold_given_stop_ppm: Option<u32>, // passthrough (hold-side wear deferred)
    pub click_given_stop_ppm: u32,
    pub cvr_ppm: u32,
    pub aov_cents: u64,
    pub fatigue_rate_x1000: i64,
}

fn bound(v: i64, lo: i64, hi: i64) -> i64 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

/// Merge deltas into a base funnel truth, keeping every rate valid.
pub fn apply(base: &BaseTruth, mods: &Mods) -> AppliedTruth {
    AppliedTruth {
        hook_ppm: bound(base.hook_ppm as i64 + mods.hook_ppm_delta, 10000, 800000) as u32,
        hold_given_stop_ppm: base.hold_given_stop_ppm,
        click_given_stop_ppm: bound(
            base.click_given_stop_ppm as i64 + mods.click_given_stop_ppm_delta,
            5000,
            500000,
        ) as u32,
        cvr_ppm: bound(base.cvr_ppm as i64 + mods.cvr_ppm_delta, 2000, 200000) as u32,
        aov_cents: base.aov_cents,
        fatigue_rate_x1000: mods.fatigue_rate_x1000,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Goldens produced by luajit on sim/resonance.lua (see /tmp/reso_golden.lua).

    #[test]
    fn new_lane_matches_luajit() {
        let lane = new_lane(42, "acme", "SOLUTION");
        assert_eq!(lane.stage_idx, 3);
        assert_eq!(lane.mults, [1119, 1146, 799, 753, 1290, 619, 1459, 588, 1167, 1030]);
        assert_eq!(
            lane.combos,
            vec![
                Combo { a: 1, b: 2, metric: 1, bonus: -269 }, // ctr
                Combo { a: 2, b: 3, metric: 0, bonus: 214 },  // hook
                Combo { a: 2, b: 9, metric: 1, bonus: 26 },   // ctr
            ]
        );
    }

    #[test]
    fn score_all_positive_matches_luajit() {
        let lane = new_lane(42, "acme", "SOLUTION");
        let v = vector(&[
            ("problem", 1), ("solution", 2), ("mechanism", 3), ("comparison", 1),
            ("social_proof", 2), ("trust", 1), ("urgency", 2), ("scarcity", 1),
            ("offer_strength", 3), ("novelty", 1),
        ]);
        let m = score(&lane, &v);
        assert_eq!(
            m,
            Mods {
                hook_ppm_delta: 75176,
                click_given_stop_ppm_delta: 29758,
                cvr_ppm_delta: 9109,
                fatigue_rate_x1000: 1150,
            }
        );
    }

    #[test]
    fn score_problem_lane_matches_luajit_and_is_order_independent() {
        let lane = new_lane(42, "copper_char", "PROBLEM");
        let expected = Mods {
            hook_ppm_delta: 35116,
            click_given_stop_ppm_delta: 13638,
            cvr_ppm_delta: 0,
            fatigue_rate_x1000: 1150,
        };
        assert_eq!(score(&lane, &vector(&[("problem", 2), ("urgency", 3)])), expected);
        // different literal order + unknown key ignored -> identical
        assert_eq!(
            score(&lane, &vector(&[("urgency", 3), ("problem", 2), ("NOT_AN_ASPECT", 9)])),
            expected
        );
    }

    #[test]
    fn apply_merges_deltas_matches_luajit() {
        let lane = new_lane(42, "acme", "SOLUTION");
        let v = vector(&[
            ("problem", 1), ("solution", 2), ("mechanism", 3), ("comparison", 1),
            ("social_proof", 2), ("trust", 1), ("urgency", 2), ("scarcity", 1),
            ("offer_strength", 3), ("novelty", 1),
        ]);
        let m = score(&lane, &v);
        let base = BaseTruth {
            hook_ppm: 300000,
            hold_given_stop_ppm: Some(400000),
            click_given_stop_ppm: 200000,
            cvr_ppm: 50000,
            aov_cents: 4999,
        };
        let t = apply(&base, &m);
        assert_eq!(t.hook_ppm, 375176);
        assert_eq!(t.hold_given_stop_ppm, Some(400000));
        assert_eq!(t.click_given_stop_ppm, 229758);
        assert_eq!(t.cvr_ppm, 59109);
        assert_eq!(t.aov_cents, 4999);
        assert_eq!(t.fatigue_rate_x1000, 1150);
    }

    #[test]
    fn clamps_and_apply_keep_rates_valid_matches_luajit() {
        let mut huge = [0i64; 10];
        for x in huge.iter_mut() {
            *x = 50;
        }
        let lane = new_lane(9, "clamp", "MOST_AWARE");
        let m = score(&lane, &huge);
        assert_eq!(
            m,
            Mods {
                hook_ppm_delta: 120000,
                click_given_stop_ppm_delta: 40000,
                cvr_ppm_delta: 15000,
                fatigue_rate_x1000: 6000,
            }
        );
        let base = BaseTruth {
            hook_ppm: 100000,
            hold_given_stop_ppm: None,
            click_given_stop_ppm: 100000,
            cvr_ppm: 30000,
            aov_cents: 1000,
        };
        let t = apply(&base, &m);
        assert_eq!(t.hook_ppm, 220000);
        assert_eq!(t.hold_given_stop_ppm, None);
        assert_eq!(t.click_given_stop_ppm, 140000);
        assert_eq!(t.cvr_ppm, 45000);
        assert_eq!(t.fatigue_rate_x1000, 6000);
    }

    #[test]
    fn urgency_fatigues_faster_than_trust_matches_luajit() {
        let lane = new_lane(5, "fat", "PRODUCT");
        let fu = score(&lane, &vector(&[("urgency", 4)])).fatigue_rate_x1000;
        let ft = score(&lane, &vector(&[("trust", 4)])).fatigue_rate_x1000;
        assert_eq!((fu, ft), (1200, 1000));
    }

    #[test]
    fn layer1_class_spot_checks_match_luajit() {
        assert_eq!(layer1_class("urgency", "UNAWARE", 3), -1);
        assert_eq!(layer1_class("problem", "PROBLEM", 1), 2);
        assert_eq!(layer1_class("social_proof", "MOST_AWARE", 2), 2);
        assert_eq!(layer1_class("offer_strength", "PRODUCT", 3), 2);
    }

    #[test]
    fn empty_vector_has_zero_deltas() {
        let lane = new_lane(42, "copper_char", "PROBLEM");
        let m = score(&lane, &[0i64; 10]);
        assert_eq!(m.hook_ppm_delta, 0);
        assert_eq!(m.click_given_stop_ppm_delta, 0);
        assert_eq!(m.cvr_ppm_delta, 0);
        assert_eq!(m.fatigue_rate_x1000, 1000);
    }
}
