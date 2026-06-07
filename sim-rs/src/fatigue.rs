//! Fatigue system. Bit-identical port of sim/fatigue.lua.
//!
//! Per-(card,lane) wear driven by cumulative FREQUENCY (impressions / lane
//! audience): onset ~2.5 cold; decay is STAGED in the real Meta order (hook,
//! then ctr|stop, then cvr). Status uses Meta's literal words. Rest regenerates;
//! each deep-fatigue cycle scars permanently (caps recovery -10%); 3 scars =
//! SPENT (retired into Learnings by the economy/ledger layer).
//!
//! Fully deterministic, no RNG. Integer state only (freq x1000, scars).
//! Lua does double division then `trunc` toward zero; every operand on those
//! paths is non-negative, so exact i64 truncating division is identical (and
//! avoids floats entirely, per the determinism invariants). Cross-validated
//! against luajit goldens below.

// onsets in freq x1000; decline slopes in mult-points per 1.0 frequency.
const ONSET_HOOK: i64 = 2500;
const ONSET_CTR: i64 = 3500;
const ONSET_CVR: i64 = 5000;
const SLOPE_HOOK: i64 = 143;
const SLOPE_CTR: i64 = 120;
const SLOPE_CVR: i64 = 60;
const FLOOR: i64 = 300; // a worn card never falls below 30% effectiveness
const LIMITED_AT: i64 = 850; // hook mult <= -> "CREATIVE LIMITED"
const FATIGUE_AT: i64 = 500; // hook mult <= -> "CREATIVE FATIGUE"
const SCAR_CAP_LOSS: i64 = 100; // permanent recovery-cap loss per deep cycle
const SPENT_SCARS: i64 = 3;
const REST_PER_DAY: i64 = 800; // freq x1000 recovered per rest day

/// Per-(card,lane) wear state. Mirrors the Lua wear table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wear {
    pub freq_x1000: i64,
    pub scars: i64,
    pub in_cycle: bool,
}

/// Effectiveness multipliers (x1000), staged + capped by permanent scarring.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mults {
    pub hook_x1000: i64,
    pub ctr_x1000: i64,
    pub cvr_x1000: i64,
}

/// Funnel truth (shared sim shape). `hold_given_stop_ppm` is an optional gate;
/// fatigue passes it through untouched (FINDINGS #3; hold-side wear deferred).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Truth {
    pub hook_ppm: i64,
    pub hold_given_stop_ppm: Option<i64>,
    pub click_given_stop_ppm: i64,
    pub cvr_ppm: i64,
    pub aov_cents: i64,
}

pub fn new_wear() -> Wear {
    Wear { freq_x1000: 0, scars: 0, in_cycle: false }
}

/// Serve `imps` impressions to a lane of `audience` people at the ad's
/// resonance fatigue rate (x1000; 1000 = baseline wear).
pub fn expose(w: &mut Wear, imps: i64, audience: i64, fatigue_rate_x1000: i64) {
    w.freq_x1000 += imps * fatigue_rate_x1000 / audience;
    // a deep-fatigue cycle scars once, when the hook mult first crosses the line
    if !w.in_cycle && mults(w).hook_x1000 <= FATIGUE_AT {
        w.in_cycle = true;
        w.scars += 1;
    }
}

/// Rest days off this lane recover frequency (never below 0). Recovering below
/// onset closes the current deep cycle.
pub fn rest(w: &mut Wear, days: i64) {
    w.freq_x1000 -= REST_PER_DAY * days;
    if w.freq_x1000 < 0 {
        w.freq_x1000 = 0;
    }
    if w.in_cycle && w.freq_x1000 < ONSET_HOOK {
        w.in_cycle = false;
    }
}

fn stage_mult(freq_x1000: i64, onset: i64, slope: i64, cap: i64) -> i64 {
    let over = freq_x1000 - onset;
    let mut m = 1000;
    if over > 0 {
        m = 1000 - slope * over / 1000;
        if m < FLOOR {
            m = FLOOR;
        }
    }
    if m > cap {
        m = cap;
    }
    m
}

/// Effectiveness multipliers (x1000), staged + capped by permanent scarring.
pub fn mults(w: &Wear) -> Mults {
    let mut cap = 1000 - SCAR_CAP_LOSS * w.scars;
    if cap < FLOOR {
        cap = FLOOR;
    }
    Mults {
        hook_x1000: stage_mult(w.freq_x1000, ONSET_HOOK, SLOPE_HOOK, cap),
        ctr_x1000: stage_mult(w.freq_x1000, ONSET_CTR, SLOPE_CTR, cap),
        cvr_x1000: stage_mult(w.freq_x1000, ONSET_CVR, SLOPE_CVR, cap),
    }
}

/// Meta's literal vocabulary (docs/01 §4) + SPENT for the retirement path.
pub fn status(w: &Wear) -> &'static str {
    if w.scars >= SPENT_SCARS {
        return "SPENT";
    }
    let hook = mults(w).hook_x1000;
    if hook <= FATIGUE_AT {
        return "CREATIVE FATIGUE";
    }
    if hook <= LIMITED_AT {
        return "CREATIVE LIMITED";
    }
    "FRESH"
}

/// Scale a funnel truth by current wear (presentation of wear to the sim).
pub fn apply_to_truth(truth: &Truth, w: &Wear) -> Truth {
    let m = mults(w);
    Truth {
        hook_ppm: truth.hook_ppm * m.hook_x1000 / 1000,
        hold_given_stop_ppm: truth.hold_given_stop_ppm, // passthrough (FINDINGS #3)
        click_given_stop_ppm: truth.click_given_stop_ppm * m.ctr_x1000 / 1000,
        cvr_ppm: truth.cvr_ppm * m.cvr_x1000 / 1000,
        aov_cents: truth.aov_cents,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden values produced by `luajit` on sim/fatigue.lua (fixed inputs).

    #[test]
    fn fresh_limited_fatigue_progression_matches_luajit() {
        let mut w = new_wear();
        // A0
        assert_eq!(w, Wear { freq_x1000: 0, scars: 0, in_cycle: false });
        assert_eq!(mults(&w), Mults { hook_x1000: 1000, ctr_x1000: 1000, cvr_x1000: 1000 });
        assert_eq!(status(&w), "FRESH");

        // A1: +2000 -> 2000 (still FRESH)
        expose(&mut w, 100000, 50000, 1000);
        assert_eq!(w, Wear { freq_x1000: 2000, scars: 0, in_cycle: false });
        assert_eq!(mults(&w), Mults { hook_x1000: 1000, ctr_x1000: 1000, cvr_x1000: 1000 });
        assert_eq!(status(&w), "FRESH");

        // A2: +2000 -> 4000 (CREATIVE LIMITED)
        expose(&mut w, 100000, 50000, 1000);
        assert_eq!(w, Wear { freq_x1000: 4000, scars: 0, in_cycle: false });
        assert_eq!(mults(&w), Mults { hook_x1000: 786, ctr_x1000: 940, cvr_x1000: 1000 });
        assert_eq!(status(&w), "CREATIVE LIMITED");

        // A3: +2000 -> 6000 (CREATIVE FATIGUE, first scar)
        expose(&mut w, 100000, 50000, 1000);
        assert_eq!(w, Wear { freq_x1000: 6000, scars: 1, in_cycle: true });
        assert_eq!(mults(&w), Mults { hook_x1000: 500, ctr_x1000: 700, cvr_x1000: 900 });
        assert_eq!(status(&w), "CREATIVE FATIGUE");

        // A4: rest 5 days -> -4000 -> 2000, cycle closes; scar persists -> cap 900
        rest(&mut w, 5);
        assert_eq!(w, Wear { freq_x1000: 2000, scars: 1, in_cycle: false });
        assert_eq!(mults(&w), Mults { hook_x1000: 900, ctr_x1000: 900, cvr_x1000: 900 });
        assert_eq!(status(&w), "FRESH");

        // A4 apply_to_truth (BASE_TRUTH from game.lua), all mults 900
        let base = Truth {
            hook_ppm: 240000,
            hold_given_stop_ppm: Some(450000),
            click_given_stop_ppm: 170000,
            cvr_ppm: 24000,
            aov_cents: 4500,
        };
        let t = apply_to_truth(&base, &w);
        assert_eq!(
            t,
            Truth {
                hook_ppm: 216000,
                hold_given_stop_ppm: Some(450000),
                click_given_stop_ppm: 153000,
                cvr_ppm: 21600,
                aov_cents: 4500,
            }
        );
    }

    #[test]
    fn non_exact_division_truncates_toward_zero_like_luajit() {
        // trunc(12345 * 1300 / 7000) == 2292
        let mut w = new_wear();
        expose(&mut w, 12345, 7000, 1300);
        assert_eq!(w.freq_x1000, 2292);
    }

    #[test]
    fn deep_cycles_drive_to_spent_matches_luajit() {
        let mut w = new_wear();
        expose(&mut w, 300000, 50000, 1000);
        rest(&mut w, 10);
        assert_eq!(w, Wear { freq_x1000: 0, scars: 1, in_cycle: false }); // B1

        expose(&mut w, 300000, 50000, 1000);
        rest(&mut w, 10);
        assert_eq!(w, Wear { freq_x1000: 0, scars: 2, in_cycle: false }); // B2

        expose(&mut w, 300000, 50000, 1000);
        assert_eq!(w, Wear { freq_x1000: 6000, scars: 3, in_cycle: true }); // B3
        assert_eq!(mults(&w), Mults { hook_x1000: 500, ctr_x1000: 700, cvr_x1000: 700 });
        assert_eq!(status(&w), "SPENT");
    }

    #[test]
    fn rest_never_below_zero() {
        let mut w = new_wear();
        expose(&mut w, 100000, 50000, 1000); // 2000
        rest(&mut w, 100); // would go very negative
        assert_eq!(w, Wear { freq_x1000: 0, scars: 0, in_cycle: false });
    }
}
