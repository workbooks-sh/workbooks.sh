//! Learning-phase shimmer + edit (SWAP) penalty. Port of sim/shimmer.lua.
//! (docs/01-game-design.md §2 FLIGHT, §5; domain.md learning phase.)
//!
//! Metrics SHIMMER (read as unreliable) until the ad banks ~10 in-game
//! conversions — the 0a-locked compressed analog of Meta's ~50/7d. Editing a
//! live ad (the SWAP verb) resets calibration, and while (re)learning,
//! delivery is genuinely worse — modeled as a flat multiplier on the
//! delivery-quality funnel rates (hook, ctr) but NOT cvr.
//!
//! Deterministic, no RNG, integer state. Lua used double arithmetic with no
//! `% 2^32` wrapping here, so the scaling uses plain (u64-widened) integer
//! division == math.floor for the non-negative inputs.

pub const CALIBRATION_CONVERSIONS: u32 = 10; // 0a-locked (spikes/0a-stats/VERDICT.md)
pub const LEARNING_DELIVERY_X1000: u32 = 850; // -15% delivery while (re)learning

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State {
    pub conversions: u32,
    pub edits: u32,
}

/// A funnel truth. `hold_given_stop_ppm` is an optional gate (Lua nil).
/// Probabilities are integer parts-per-million; money is integer cents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Truth {
    pub hook_ppm: u32,
    pub hold_given_stop_ppm: Option<u32>,
    pub click_given_stop_ppm: u32,
    pub cvr_ppm: u32,
    pub aov_cents: u32,
}

/// math.floor(x * m / 1000) for non-negative integers; u64 widen avoids
/// overflow (matches Lua double arithmetic, which never wraps here).
fn scale(x: u32, m: u32) -> u32 {
    ((x as u64 * m as u64) / 1000) as u32
}

pub fn new_state() -> State {
    State { conversions: 0, edits: 0 }
}

pub fn on_conversion(s: &mut State) {
    s.conversions += 1;
}

/// The SWAP verb (and any live edit) lands here.
pub fn on_edit(s: &mut State) {
    s.conversions = 0;
    s.edits += 1;
}

pub fn is_calibrated(s: &State) -> bool {
    s.conversions >= CALIBRATION_CONVERSIONS
}

/// 1000 = full shimmer (no evidence) -> 0 = calibrated. Linear in evidence.
pub fn shimmer_x1000(s: &State) -> u32 {
    let left: i64 = 1000 - 100 * s.conversions as i64;
    if left < 0 { 0 } else { left as u32 }
}

pub fn delivery_mult_x1000(s: &State) -> u32 {
    if is_calibrated(s) { 1000 } else { LEARNING_DELIVERY_X1000 }
}

/// Scale a funnel truth by the current learning state. The penalty hits
/// DELIVERY QUALITY (hook, ctr) but NOT cvr; hold is a passthrough.
pub fn apply_to_truth(truth: &Truth, s: &State) -> Truth {
    let m = delivery_mult_x1000(s);
    Truth {
        hook_ppm: scale(truth.hook_ppm, m),
        hold_given_stop_ppm: truth.hold_given_stop_ppm, // passthrough (FINDINGS #3)
        click_given_stop_ppm: scale(truth.click_given_stop_ppm, m),
        cvr_ppm: truth.cvr_ppm,
        aov_cents: truth.aov_cents,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // All goldens below produced by luajit on sim/shimmer.lua.

    #[test]
    fn constants_match_luajit() {
        assert_eq!(CALIBRATION_CONVERSIONS, 10);
        assert_eq!(LEARNING_DELIVERY_X1000, 850);
    }

    #[test]
    fn new_state_matches_luajit() {
        let s = new_state();
        assert_eq!(s, State { conversions: 0, edits: 0 });
    }

    fn mk(c: u32) -> State {
        let mut s = new_state();
        s.conversions = c;
        s
    }

    #[test]
    fn shimmer_and_delivery_match_luajit() {
        // (conversions, shimmer_x1000, delivery_mult_x1000, is_calibrated)
        let cases: [(u32, u32, u32, bool); 7] = [
            (0, 1000, 850, false),
            (1, 900, 850, false),
            (5, 500, 850, false),
            (9, 100, 850, false),
            (10, 0, 1000, true),
            (11, 0, 1000, true),
            (15, 0, 1000, true),
        ];
        for (c, sh, dl, cal) in cases {
            let s = mk(c);
            assert_eq!(shimmer_x1000(&s), sh, "shimmer c={}", c);
            assert_eq!(delivery_mult_x1000(&s), dl, "delivery c={}", c);
            assert_eq!(is_calibrated(&s), cal, "calib c={}", c);
        }
    }

    #[test]
    fn transitions_match_luajit() {
        let mut s = new_state();
        for _ in 0..12 {
            on_conversion(&mut s);
        }
        assert_eq!(s.conversions, 12);
        assert!(is_calibrated(&s));
        assert_eq!(shimmer_x1000(&s), 0);
        assert_eq!(delivery_mult_x1000(&s), 1000);

        on_edit(&mut s);
        assert_eq!(s.conversions, 0);
        assert_eq!(s.edits, 1);
        assert!(!is_calibrated(&s));
        assert_eq!(shimmer_x1000(&s), 1000);
        assert_eq!(delivery_mult_x1000(&s), 850);
    }

    #[test]
    fn apply_to_truth_matches_luajit() {
        let truth = Truth {
            hook_ppm: 120000,
            hold_given_stop_ppm: Some(400000),
            click_given_stop_ppm: 90000,
            cvr_ppm: 25000,
            aov_cents: 4999,
        };

        // uncalibrated (conv=3): m=850
        let tu = apply_to_truth(&truth, &mk(3));
        assert_eq!(
            tu,
            Truth {
                hook_ppm: 102000,
                hold_given_stop_ppm: Some(400000),
                click_given_stop_ppm: 76500,
                cvr_ppm: 25000,
                aov_cents: 4999,
            }
        );

        // calibrated (conv=10): m=1000, untouched
        let tc = apply_to_truth(&truth, &mk(10));
        assert_eq!(tc, truth);

        // truncation edge, hold = None, uncalibrated (conv=7)
        let truth2 = Truth {
            hook_ppm: 12345,
            hold_given_stop_ppm: None,
            click_given_stop_ppm: 67891,
            cvr_ppm: 33333,
            aov_cents: 1,
        };
        let t2 = apply_to_truth(&truth2, &mk(7));
        assert_eq!(
            t2,
            Truth {
                hook_ppm: 10493,
                hold_given_stop_ppm: None,
                click_given_stop_ppm: 57707,
                cvr_ppm: 33333,
                aov_cents: 1,
            }
        );
    }
}
