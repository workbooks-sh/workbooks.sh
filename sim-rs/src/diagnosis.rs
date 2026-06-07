//! Diagnosis engine. Port of sim/diagnosis.lua (docs/01-game-design.md §2
//! AUTOPSY). The 6-case rule table, v1 floor — pure deterministic function of
//! observations, NO RNG. Integer parts-per-million ratios (x1e6); no floats in
//! the decision path. Cross-validated vs luajit goldens (see #[cfg(test)]).
//!
//! The 6 cases (funnel order):
//!   LOW_HOOK          low stop rate        -> the first 3 seconds
//!   BAIT_AND_SWITCH   stop, then no hold   -> hook promised what the ad lacks
//!   NO_REASON_TO_ACT  hold, then no click  -> nothing asks for the click
//!   AD_PAGE_MISMATCH  click, then no buy   -> the lander breaks the promise
//!   FATIGUE           was good, now tired  -> TEMPORAL: needs history + wear
//!   WRONG_ANGLE       all gates mediocre   -> kill and re-concept

/// Guess chips: four gates + FATIGUE + NO_SINGLE_LEAK. Mirrors Diagnosis.CHIPS.
pub const CHIPS: [&str; 6] = ["HOOK", "HOLD", "CTR", "CVR", "FATIGUE", "NO_SINGLE_LEAK"];

const N_FLOOR_IMPS: i64 = 2000;
const CVR_MIN_CLICKS: i64 = 50;
const FATIGUE_WINDOW_IMPS: i64 = 2000;
const FATIGUE_DROP_X1000: i64 = 800; // late hook < 80% of early hook

// gate bands: below LO = leaking; LO..OK = mediocre; >= OK = healthy (x1e6)
const HOOK_LO: i64 = 150000; // stops/imps
const HOOK_OK: i64 = 240000;
const HOLD_LO: i64 = 300000; // holds/stops
const HOLD_OK: i64 = 420000;
const CLICK_LO: i64 = 80000; // clicks/holds
const CLICK_OK: i64 = 140000;
const CVR_LO: i64 = 8000; // buys/clicks
const CVR_OK: i64 = 18000;

/// An early/late observation window for the temporal (tired-vs-wrong) check.
#[derive(Clone, Copy, Default)]
pub struct Window {
    pub imps: i64,
    pub stops: i64,
}

/// Aggregate observations of one creative. Optional early/late/wear_status drive
/// the FATIGUE temporal check (mirrors the Lua obs table fields).
#[derive(Clone, Copy, Default)]
pub struct Obs<'a> {
    pub imps: i64,
    pub stops: i64,
    pub holds: i64,
    pub clicks: i64,
    pub buys: i64,
    pub early: Option<Window>,
    pub late: Option<Window>,
    pub wear_status: Option<&'a str>,
}

/// A diagnosis verdict. `case` and `chip` are stable identifiers; `sentence` is
/// the player-facing copy (the only owned/formatted field).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub case: &'static str,
    pub chip: &'static str,
    pub sentence: String,
}

fn ratio_x1e6(num: i64, den: i64) -> i64 {
    if den == 0 {
        return 0;
    }
    num * 1_000_000 / den
}

/// Evidence floor: below N_FLOOR_IMPS there is no diagnosis and nothing to grade.
pub fn diagnosable(obs: &Obs) -> bool {
    obs.imps >= N_FLOOR_IMPS
}

fn chip_for(case: &str) -> &'static str {
    match case {
        "LOW_HOOK" => "HOOK",
        "BAIT_AND_SWITCH" => "HOLD",
        "NO_REASON_TO_ACT" => "CTR",
        "AD_PAGE_MISMATCH" => "CVR",
        "FATIGUE" => "FATIGUE",
        "WRONG_ANGLE" => "NO_SINGLE_LEAK",
        _ => "",
    }
}

fn sentence_for(case: &str, detail: i64) -> String {
    match case {
        "LOW_HOOK" => format!(
            "Only {}% stop — the first 3 seconds aren't earning attention. New hook.",
            detail
        ),
        "BAIT_AND_SWITCH" => "They stop, then bail — the hook promises something the ad never follows through on. Match what opens to what follows.".to_string(),
        "NO_REASON_TO_ACT" => "They watch and drift — nothing asks for the click. Add a clear ask at the end.".to_string(),
        "AD_PAGE_MISMATCH" => "Clicks are fine; the page loses them — what the ad promises, the destination doesn't deliver. Align the two.".to_string(),
        "FATIGUE" => "This creative isn't wrong, it's tired — it ran well before but keeps showing to the same people. Rest it or try a variation.".to_string(),
        "WRONG_ANGLE" => "No single leak — everything is mediocre at once. Wrong concept or audience: kill it and start fresh.".to_string(),
        _ => String::new(),
    }
}

fn verdict(case: &'static str, detail: i64) -> Verdict {
    Verdict {
        case,
        chip: chip_for(case),
        sentence: sentence_for(case, detail),
    }
}

/// Diagnose one creative. Returns None when not diagnosable or healthy (no
/// manufactured problems). Decision order is load-bearing for determinism.
pub fn diagnose(obs: &Obs) -> Option<Verdict> {
    if !diagnosable(obs) {
        return None;
    }

    // FATIGUE first: temporal evidence + wear status beats any static reading —
    // a tired ad LOOKS like a hook problem; history is what tells them apart.
    if let (Some(early), Some(late), Some(wear)) = (obs.early, obs.late, obs.wear_status) {
        if wear != "FRESH"
            && early.imps >= FATIGUE_WINDOW_IMPS
            && late.imps >= FATIGUE_WINDOW_IMPS
        {
            let early_hook = ratio_x1e6(early.stops, early.imps);
            let late_hook = ratio_x1e6(late.stops, late.imps);
            if late_hook * 1000 < early_hook * FATIGUE_DROP_X1000 {
                return Some(verdict("FATIGUE", 0));
            }
        }
    }

    let hook = ratio_x1e6(obs.stops, obs.imps);
    let hold = ratio_x1e6(obs.holds, obs.stops);
    let click = ratio_x1e6(obs.clicks, obs.holds);
    let cvr = if obs.clicks >= CVR_MIN_CLICKS {
        Some(ratio_x1e6(obs.buys, obs.clicks))
    } else {
        None
    };

    // first leaking gate in funnel order
    if hook < HOOK_LO {
        return Some(verdict("LOW_HOOK", hook / 10000));
    }
    if hold < HOLD_LO {
        return Some(verdict("BAIT_AND_SWITCH", 0));
    }
    if click < CLICK_LO {
        return Some(verdict("NO_REASON_TO_ACT", 0));
    }
    if let Some(c) = cvr {
        if c < CVR_LO {
            return Some(verdict("AD_PAGE_MISMATCH", 0));
        }
    }

    // no single leak: count mediocre gates (LO..OK)
    let mut mediocre = 0;
    if hook < HOOK_OK {
        mediocre += 1;
    }
    if hold < HOLD_OK {
        mediocre += 1;
    }
    if click < CLICK_OK {
        mediocre += 1;
    }
    if let Some(c) = cvr {
        if c < CVR_OK {
            mediocre += 1;
        }
    }
    if mediocre >= 3 {
        return Some(verdict("WRONG_ANGLE", 0));
    }

    None // healthy: no manufactured problems
}

/// Grade a player's guess chip against a verdict's expected chip.
pub fn grade_guess(diag: &Verdict, chip: &str) -> &'static str {
    if diag.chip == chip {
        "CORRECT"
    } else {
        "WRONG"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden values produced by luajit on sim/diagnosis.lua (fixed obs inputs).

    fn obs5(imps: i64, stops: i64, holds: i64, clicks: i64, buys: i64) -> Obs<'static> {
        Obs { imps, stops, holds, clicks, buys, ..Default::default() }
    }

    #[test]
    fn diagnosable_floor() {
        assert!(!diagnosable(&obs5(1000, 0, 0, 0, 0)));
        assert!(diagnosable(&obs5(2000, 0, 0, 0, 0)));
    }

    #[test]
    fn undiagnosable_returns_none() {
        // T1: imps below floor
        assert_eq!(diagnose(&obs5(1000, 10, 5, 2, 1)), None);
    }

    #[test]
    fn low_hook() {
        // T2
        let v = diagnose(&obs5(10000, 1000, 500, 100, 10)).unwrap();
        assert_eq!(v.case, "LOW_HOOK");
        assert_eq!(v.chip, "HOOK");
        assert_eq!(
            v.sentence,
            "Only 10% stop — the first 3 seconds aren't earning attention. New hook."
        );
    }

    #[test]
    fn bait_and_switch() {
        // T3
        let v = diagnose(&obs5(10000, 2000, 400, 100, 10)).unwrap();
        assert_eq!(v.case, "BAIT_AND_SWITCH");
        assert_eq!(v.chip, "HOLD");
        assert_eq!(
            v.sentence,
            "They stop, then bail — the hook promised something the ad never delivers. Re-align hook and body."
        );
    }

    #[test]
    fn no_reason_to_act() {
        // T4
        let v = diagnose(&obs5(10000, 2000, 1000, 40, 5)).unwrap();
        assert_eq!(v.case, "NO_REASON_TO_ACT");
        assert_eq!(v.chip, "CTR");
        assert_eq!(
            v.sentence,
            "They watch and drift — nothing asks for the click. Sharpen the offer and CTA."
        );
    }

    #[test]
    fn ad_page_mismatch() {
        // T5
        let v = diagnose(&obs5(10000, 2000, 1000, 200, 1)).unwrap();
        assert_eq!(v.case, "AD_PAGE_MISMATCH");
        assert_eq!(v.chip, "CVR");
        assert_eq!(
            v.sentence,
            "Clicks are fine; the page kills it — the ad writes a check the lander won't cash."
        );
    }

    #[test]
    fn wrong_angle() {
        // T6
        let v = diagnose(&obs5(10000, 2000, 700, 70, 1)).unwrap();
        assert_eq!(v.case, "WRONG_ANGLE");
        assert_eq!(v.chip, "NO_SINGLE_LEAK");
        assert_eq!(
            v.sentence,
            "No single leak — everything is mediocre at once. Wrong angle or audience: kill it and re-concept; don't iterate."
        );
    }

    #[test]
    fn fatigue() {
        // T7
        let o = Obs {
            imps: 10000,
            stops: 2000,
            holds: 1000,
            clicks: 200,
            buys: 50,
            early: Some(Window { imps: 5000, stops: 1000 }),
            late: Some(Window { imps: 5000, stops: 500 }),
            wear_status: Some("WORN"),
        };
        let v = diagnose(&o).unwrap();
        assert_eq!(v.case, "FATIGUE");
        assert_eq!(v.chip, "FATIGUE");
        assert_eq!(
            v.sentence,
            "This creative isn't wrong, it's tired — it performed before and is decaying with frequency. Rest it or mint a V2."
        );
    }

    #[test]
    fn healthy_returns_none() {
        // T8
        assert_eq!(diagnose(&obs5(10000, 3000, 2000, 1000, 300)), None);
    }

    #[test]
    fn grade_guess_matches() {
        let v = diagnose(&obs5(10000, 1000, 500, 100, 10)).unwrap();
        assert_eq!(grade_guess(&v, "HOOK"), "CORRECT");
        assert_eq!(grade_guess(&v, "HOLD"), "WRONG");
    }

    #[test]
    fn chips_table() {
        assert_eq!(CHIPS, ["HOOK", "HOLD", "CTR", "CVR", "FATIGUE", "NO_SINGLE_LEAK"]);
    }
}
