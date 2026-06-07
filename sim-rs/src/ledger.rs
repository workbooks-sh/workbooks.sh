//! Pin / Field Note / Codex ledger. Port of sim/ledger.lua (docs/01-game-design.md
//! §2 AUTOPSY, §5). The epistemic pipeline: graded pins -> Field Notes (run-scoped
//! knowledge currency) -> Codex (account-scoped curriculum tracker).
//!   - only CLEAN pairs mint notes, and they mint on the EVIDENCE (winner's
//!     direction), not the player's call -- a BUSTED clean test still teaches;
//!   - dirty pins are bets: graded, never minted;
//!   - nulls bank as direction-0 notes (negative knowledge is knowledge);
//!   - notes narrow forecast bands on matching compositions, floored;
//!   - the Codex canonizes a claim only when confirmed in 2 DISTINCT runs.
//! Pure deterministic functions; no RNG; ordered storage (no map iteration in
//! order-dependent paths -- `notes` is a Vec, `by_key` is only an index lookup).

use std::collections::{HashMap, HashSet};

pub const BAND_FLOOR_X1000: i32 = 400;
const NARROW_PER_EVIDENCE: i32 = 150;
const EVIDENCE_CAP_PER_NOTE: i32 = 3;

/// `aspect:stage:metric:direction` -- mirrors the Lua `claim_key`/`bank` keys.
/// `tostring(direction)` of an integer-valued Lua number == Rust `{}` of an i32.
fn claim_key(aspect: &str, stage: &str, metric: &str, direction: i32) -> String {
    format!("{}:{}:{}:{}", aspect, stage, metric, direction)
}

// ----------------------------------------------------------------- claims/pins

/// A claim identity (aspect, stage, metric, direction).
#[derive(Clone)]
pub struct Claim {
    pub aspect: String,
    pub stage: String,
    pub metric: String,
    pub direction: i32,
}

/// A graded pin arriving from the wave machine's autopsy.
#[derive(Clone)]
pub struct Pin {
    pub verdict: String,
    pub clean: bool,
    pub aspect: String,
    pub stage: String,
    pub metric: String,
    pub direction: i32,
}

/// A minted Field Note. `n` is the evidence count for this exact claim.
#[derive(Clone)]
pub struct Note {
    pub aspect: String,
    pub stage: String,
    pub metric: String,
    pub direction: i32,
    pub n: i32,
}

// -------------------------------------------------------------------- run ledger

pub struct RunLedger {
    /// Ordered list of notes (insertion order preserved; iterated deterministically).
    pub notes: Vec<Note>,
    /// claim_key -> index into `notes`. Lookup only; never order-iterated.
    by_key: HashMap<String, usize>,
}

pub fn new_run_ledger() -> RunLedger {
    RunLedger { notes: Vec::new(), by_key: HashMap::new() }
}

/// Bank evidence for a claim: bump `n` if seen, else append a fresh note.
/// Returns the index of the note in `led.notes`.
fn bank(led: &mut RunLedger, aspect: &str, stage: &str, metric: &str, direction: i32) -> usize {
    let key = claim_key(aspect, stage, metric, direction);
    if let Some(&idx) = led.by_key.get(&key) {
        led.notes[idx].n += 1;
        return idx;
    }
    led.notes.push(Note {
        aspect: aspect.to_string(),
        stage: stage.to_string(),
        metric: metric.to_string(),
        direction,
        n: 1,
    });
    let idx = led.notes.len() - 1;
    led.by_key.insert(key, idx);
    idx
}

/// Record a graded pin. Returns the minted/updated Field Note, or None when
/// nothing mints (dirty pin = just a bet; INCONCLUSIVE = carry-over owns it).
pub fn record_pin<'a>(led: &'a mut RunLedger, pin: &Pin) -> Option<&'a Note> {
    if !pin.clean {
        return None;
    }
    if pin.verdict == "INCONCLUSIVE" {
        return None;
    }
    let idx = bank(led, &pin.aspect, &pin.stage, &pin.metric, pin.direction);
    Some(&led.notes[idx])
}

/// Null results auto-bank as direction-0 notes (no detectable lift).
pub fn record_null<'a>(led: &'a mut RunLedger, claim: &Claim) -> &'a Note {
    let idx = bank(led, &claim.aspect, &claim.stage, &claim.metric, 0);
    &led.notes[idx]
}

pub fn field_notes(led: &RunLedger) -> &[Note] {
    &led.notes
}

/// Forecast-band width multiplier (x1000) for a composition on a lane stage.
/// Notes match when their stage equals the lane's AND the composition carries
/// their aspect (value > 0). Monotone narrowing with per-note evidence caps and
/// a floor.
pub fn band_x1000(led: &RunLedger, composition_aspects: &HashMap<String, i32>, stage: &str) -> i32 {
    let mut evidence = 0;
    for note in &led.notes {
        if note.stage == stage {
            if let Some(&w) = composition_aspects.get(&note.aspect) {
                if w > 0 {
                    let mut n = note.n;
                    if n > EVIDENCE_CAP_PER_NOTE {
                        n = EVIDENCE_CAP_PER_NOTE;
                    }
                    evidence += n;
                }
            }
        }
    }
    let mut band = 1000 - NARROW_PER_EVIDENCE * evidence;
    if band < BAND_FLOOR_X1000 {
        band = BAND_FLOOR_X1000;
    }
    band
}

// -------------------------------------------------------------------------- codex

pub struct CodexEntry {
    /// Distinct run ids that have observed this claim, in observation order.
    pub runs: Vec<String>,
    run_set: HashSet<String>,
}

pub struct Codex {
    /// claim_key -> entry. Order-independent (counts only); map iteration ok.
    pub claims: HashMap<String, CodexEntry>,
}

pub struct Progress {
    pub canon: i32,
    pub observed: i32,
}

pub fn new_codex() -> Codex {
    Codex { claims: HashMap::new() }
}

pub fn codex_observe(codex: &mut Codex, run_id: &str, claim: &Claim) {
    let key = claim_key(&claim.aspect, &claim.stage, &claim.metric, claim.direction);
    let entry = codex
        .claims
        .entry(key)
        .or_insert_with(|| CodexEntry { runs: Vec::new(), run_set: HashSet::new() });
    if entry.run_set.insert(run_id.to_string()) {
        entry.runs.push(run_id.to_string());
    }
}

pub fn codex_status(codex: &Codex, claim: &Claim) -> &'static str {
    let key = claim_key(&claim.aspect, &claim.stage, &claim.metric, claim.direction);
    match codex.claims.get(&key) {
        None => "UNSEEN",
        Some(entry) if entry.runs.len() >= 2 => "CANON",
        Some(_) => "OBSERVED",
    }
}

pub fn codex_progress(codex: &Codex) -> Progress {
    let mut canon = 0;
    let mut observed = 0;
    for entry in codex.claims.values() {
        if entry.runs.len() >= 2 {
            canon += 1;
        } else {
            observed += 1;
        }
    }
    Progress { canon, observed }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pin(verdict: &str, clean: bool, aspect: &str, stage: &str, metric: &str, dir: i32) -> Pin {
        Pin {
            verdict: verdict.into(),
            clean,
            aspect: aspect.into(),
            stage: stage.into(),
            metric: metric.into(),
            direction: dir,
        }
    }

    fn claim(aspect: &str, stage: &str, metric: &str, dir: i32) -> Claim {
        Claim { aspect: aspect.into(), stage: stage.into(), metric: metric.into(), direction: dir }
    }

    fn comp(pairs: &[(&str, i32)]) -> HashMap<String, i32> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    // ---- goldens captured from `luajit golden_ledger.lua` on sim/ledger.lua ----

    #[test]
    fn run_ledger_matches_luajit() {
        let mut led = new_run_ledger();

        // clean + CONFIRMED mints taxonomy-level knowledge.
        {
            let note = record_pin(&mut led, &pin("CONFIRMED", true, "urgency", "PROBLEM", "HOOK", 1))
                .expect("clean confirmed pin mints a note");
            assert_eq!(note.aspect, "urgency"); // pin1.aspect=urgency
            assert_eq!(note.direction, 1); // dir=1
            assert_eq!(note.n, 1); // n=1
        }
        assert_eq!(field_notes(&led).len(), 1); // count_after_pin1=1

        // clean + BUSTED still mints -- direction follows the WINNER.
        {
            let nb = record_pin(&mut led, &pin("BUSTED", true, "novelty", "PROBLEM", "HOOK", -1))
                .expect("busted clean still yields attribution");
            assert_eq!(nb.direction, -1); // pin_busted.dir=-1
        }

        // dirty pins are just bets -- mint nothing, ledger unchanged.
        assert!(record_pin(&mut led, &pin("CONFIRMED", false, "trust", "PROBLEM", "HOOK", 1)).is_none());
        assert_eq!(field_notes(&led).len(), 2); // count=2

        // INCONCLUSIVE mints nothing.
        assert!(record_pin(&mut led, &pin("INCONCLUSIVE", true, "trust", "PROBLEM", "HOOK", 0)).is_none());

        // nulls auto-bank as direction-0 knowledge.
        {
            let nn = record_null(&mut led, &claim("scarcity", "COLD", "HOOK", 0));
            assert_eq!(nn.direction, 0); // null.dir=0
        }
        assert_eq!(field_notes(&led).len(), 3); // count=3

        // repeat evidence stacks n, not duplicate notes.
        record_pin(&mut led, &pin("CONFIRMED", true, "urgency", "PROBLEM", "HOOK", 1));
        assert_eq!(field_notes(&led).len(), 3); // count_after_stack=3
        assert_eq!(field_notes(&led)[0].n, 2); // urgency_note.n=2

        // forecast bands narrow only on matching compositions.
        assert_eq!(band_x1000(&led, &comp(&[("trust", 3)]), "SOLUTION"), 1000); // band_full
        assert_eq!(band_x1000(&led, &comp(&[("urgency", 3)]), "PROBLEM"), 700); // band_narrowed
    }

    #[test]
    fn band_evidence_caps_and_floor_match_luajit() {
        // single match, n=1 (no cap): 1000 - 150 = 850.
        let mut led3 = new_run_ledger();
        record_pin(&mut led3, &pin("CONFIRMED", true, "urgency", "PROBLEM", "HOOK", 1));
        assert_eq!(band_x1000(&led3, &comp(&[("urgency", 1)]), "PROBLEM"), 850); // band_one

        // deep evidence: two aspects each n=10, capped to 3 -> evidence 6 ->
        // 1000 - 900 = 100, floored to 400.
        let mut led2 = new_run_ledger();
        for _ in 0..10 {
            record_pin(&mut led2, &pin("CONFIRMED", true, "urgency", "PROBLEM", "HOOK", 1));
            record_pin(&mut led2, &pin("CONFIRMED", true, "problem", "PROBLEM", "HOOK", 1));
        }
        assert_eq!(band_x1000(&led2, &comp(&[("urgency", 3), ("problem", 2)]), "PROBLEM"), 400); // band_deep
        assert_eq!(BAND_FLOOR_X1000, 400);
    }

    #[test]
    fn codex_matches_luajit() {
        let mut codex = new_codex();
        let key = claim("urgency", "PROBLEM", "HOOK", 1);

        assert_eq!(codex_status(&codex, &key), "UNSEEN"); // status0
        codex_observe(&mut codex, "run_A", &key);
        assert_eq!(codex_status(&codex, &key), "OBSERVED"); // status1
        codex_observe(&mut codex, "run_A", &key); // same run again != replication
        assert_eq!(codex_status(&codex, &key), "OBSERVED"); // status_same
        codex_observe(&mut codex, "run_B", &key);
        assert_eq!(codex_status(&codex, &key), "CANON"); // status2

        // direction matters -- opposite direction is a different claim.
        let key_neg = claim("urgency", "PROBLEM", "HOOK", -1);
        assert_eq!(codex_status(&codex, &key_neg), "UNSEEN"); // status_neg

        let prog = codex_progress(&codex);
        assert_eq!(prog.canon, 1); // prog.canon=1
        assert_eq!(prog.observed, 0); // prog.observed=0
    }
}
