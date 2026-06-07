//! Strategist hypothesis engine. Faithful port of sim/strategist.lua
//! (docs/design/ad-builder-and-assets.md §6, team-cards.md traits).
//!
//! Hires with strategy roles emit PROPOSALS: suggested Pins pointing at
//! (aspect x stage x metric x direction) claims. THE LAWS:
//!   1. propose, never decide -- pure suggestion data; nothing is launched,
//!      graded, or written by this module;
//!   2. traits shape distribution + framing ONLY: skill sets the true hit-rate
//!      (P(direction matches the Layer-1 sign)); confidence bias scales the
//!      CLAIMED confidence; style picks novel vs evidenced aspects. Nothing
//!      here touches truth or significance;
//!   3. calibration is discoverable: the claimed-vs-actual gap is a stable,
//!      per-hire property, surfaced through the track record.
//!
//! Deps mirror the Lua `require`s exactly -- only crate::rng + crate::resonance.
//! The ledger is duck-typed (the Lua reads `ledger.notes[i].aspect`), so propose
//! takes the run ledger's note aspects as a plain slice rather than coupling to
//! crate::ledger. rng call order/count is load-bearing -- do NOT reorder.
use crate::resonance;
use crate::rng::Rng;

/// Calibration/style data riding along on a hire (team-cards.md traits).
#[derive(Clone)]
pub struct Traits {
    /// True hit-rate per mille: P(proposed direction == Layer-1 sign).
    pub skill_x1000: i64,
    /// Scales the CLAIMED confidence only -- never the substance.
    pub confidence_bias_x1000: i64,
    /// "creative" explores fresh aspects; anything else exploits noted ones.
    pub style: String,
}

/// A hire definition (the subset the strategist consumes).
#[derive(Clone)]
pub struct HireDef {
    pub id: String,
    pub traits: Traits,
}

#[derive(Clone)]
struct Track {
    graded: i64,
    hits: i64,
}

/// A live strategist instance (mirrors the Lua `s` table).
#[derive(Clone)]
pub struct Strategist {
    pub id: String,
    pub traits: Traits,
    rng: Rng,
    track: Track,
}

/// A single proposal -- suggestion data only (LAW 1). Mirrors the Lua table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proposal {
    pub kind: &'static str, // always "pin_suggestion"
    pub by: String,         // s.id
    pub aspect: String,
    pub stage: String,
    pub metric: &'static str, // "HOOK" | "CTR" | "CVR"
    pub direction: i64,       // +1 or -1
    pub claimed_confidence_x1000: i64,
    pub rationale: &'static str,
}

/// propose() context. `noted_aspects` is the set of aspects the run ledger
/// already has notes on (duplicates ok -- deduped internally), e.g.
/// `led.notes.iter().map(|n| n.aspect.as_str()).collect::<Vec<_>>()`.
pub struct Ctx<'a> {
    pub stage: &'a str,
    pub noted_aspects: &'a [&'a str],
    pub count: u32,
}

/// Track-record view (the visible calibration display).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrackRecord {
    pub graded: i64,
    pub hits: i64,
    pub hit_rate_x1000: i64,
}

// metric names emitted by proposals (uppercase; distinct from resonance keys).
const METRIC_NAMES: [&str; 3] = ["HOOK", "CTR", "CVR"];

/// Best metric for an aspect at a stage: the one with the largest |class|.
/// Returns (metric name, true sign), or None when the aspect is silent.
/// Ties resolve to the earliest metric (HOOK > CTR > CVR), like the Lua `>`.
fn best_claim(aspect: &str, stage: &str) -> Option<(&'static str, i64)> {
    let mut best_i: Option<usize> = None; // 1-based
    let mut best_abs: i64 = 0;
    let mut best_sign: i64 = 0;
    for mi in 1..=3usize {
        let class = resonance::layer1_class(aspect, stage, mi);
        let abs = if class >= 0 { class } else { -class };
        if abs > best_abs {
            best_i = Some(mi);
            best_abs = abs;
            best_sign = if class > 0 { 1 } else { -1 };
        }
    }
    best_i.map(|i| (METRIC_NAMES[i - 1], best_sign))
}

/// Aspects split by whether the run ledger already has notes on them.
/// Both pools follow canonical ASPECTS order (input order is irrelevant).
fn candidate_pools(noted_aspects: &[&str]) -> (Vec<&'static str>, Vec<&'static str>) {
    let mut fresh: Vec<&'static str> = Vec::new();
    let mut known: Vec<&'static str> = Vec::new();
    for &a in resonance::ASPECTS.iter() {
        if noted_aspects.iter().any(|&x| x == a) {
            known.push(a);
        } else {
            fresh.push(a);
        }
    }
    (fresh, known)
}

fn clamp(v: i64, lo: i64, hi: i64) -> i64 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

impl Strategist {
    pub fn new(seed: u32, hiredef: HireDef) -> Strategist {
        let rng = Rng::substream(seed, &format!("strategist:{}", hiredef.id));
        Strategist {
            id: hiredef.id,
            traits: hiredef.traits,
            rng,
            track: Track { graded: 0, hits: 0 },
        }
    }

    /// Emit up to `ctx.count` proposals. rng draw order per iteration:
    ///   1 (cross) + 1..10 (pool picks until a testable aspect) + 1 (hit, only
    ///   if a testable aspect was found). Any reorder breaks determinism.
    pub fn propose(&mut self, ctx: &Ctx) -> Vec<Proposal> {
        let (fresh, known) = candidate_pools(ctx.noted_aspects);
        let skill = self.traits.skill_x1000;
        let bias = self.traits.confidence_bias_x1000;
        let creative = self.traits.style == "creative";
        let mut proposals: Vec<Proposal> = Vec::new();

        for _ in 0..ctx.count {
            // style picks the pool, with a small crossover chance; falls back
            // when a pool is empty.
            let cross = self.rng.next_u32() % 100 < 15;
            let mut pool: &[&str] = if creative {
                if !cross && !fresh.is_empty() {
                    &fresh
                } else {
                    &known
                }
            } else if !cross && !known.is_empty() {
                &known
            } else {
                &fresh
            };
            if pool.is_empty() {
                pool = if !fresh.is_empty() { &fresh } else { &known };
            }

            // pick an aspect that actually has a testable claim at this stage
            let mut found: Option<(&'static str, &'static str, i64)> = None;
            for _ in 0..10 {
                let idx = (self.rng.next_u32() % pool.len() as u32) as usize;
                let candidate = pool[idx];
                if let Some((m, sign)) = best_claim(candidate, ctx.stage) {
                    found = Some((candidate, m, sign));
                    break;
                }
            }

            if let Some((aspect, metric, true_sign)) = found {
                // skill = the true hit-rate: direction matches the Layer-1 sign
                // that often.
                let hit = ((self.rng.next_u32() % 1000) as i64) < skill;
                let direction = if hit { true_sign } else { -true_sign };
                proposals.push(Proposal {
                    kind: "pin_suggestion",
                    by: self.id.clone(),
                    aspect: aspect.to_string(),
                    stage: ctx.stage.to_string(),
                    metric,
                    direction,
                    claimed_confidence_x1000: clamp(skill * bias / 1000, 100, 990),
                    rationale: if creative {
                        "hunch: untested territory"
                    } else {
                        "pattern-adjacent: builds on the ledger"
                    },
                });
            }
        }
        proposals
    }

    pub fn record_grade(&mut self, verdict: &str) {
        if verdict == "INCONCLUSIVE" {
            return;
        }
        self.track.graded += 1;
        if verdict == "CONFIRMED" {
            self.track.hits += 1;
        }
    }

    pub fn track_record(&self) -> TrackRecord {
        let rate = if self.track.graded > 0 {
            1000 * self.track.hits / self.track.graded
        } else {
            0
        };
        TrackRecord {
            graded: self.track.graded,
            hits: self.track.hits,
            hit_rate_x1000: rate,
        }
    }
}

/// Mock-side oracle: does the proposal point at the true Layer-1 sign? In the
/// game, grading happens through real pin outcomes; this is the harness's
/// ground-truth check for calibration math.
pub fn grade_against_truth(p: &Proposal) -> bool {
    match best_claim(&p.aspect, &p.stage) {
        Some((_, sign)) => p.direction == sign,
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Goldens from `luajit /tmp/strat_golden.lua` on sim/strategist.lua.

    fn hire(id: &str, bias: i64, style: &str, skill: i64) -> HireDef {
        HireDef {
            id: id.to_string(),
            traits: Traits {
                skill_x1000: skill,
                confidence_bias_x1000: bias,
                style: style.to_string(),
            },
        }
    }

    // (aspect, metric, direction) substance triples for compact comparison.
    fn substance(props: &[Proposal]) -> Vec<(String, &'static str, i64)> {
        props
            .iter()
            .map(|p| (p.aspect.clone(), p.metric, p.direction))
            .collect()
    }

    #[test]
    fn case_a_creative_problem_matches_luajit() {
        let noted = ["urgency", "problem"];
        let mut s = Strategist::new(42, hire("s_creative_650", 1300, "creative", 650));
        let props = s.propose(&Ctx { stage: "PROBLEM", noted_aspects: &noted, count: 3 });
        assert_eq!(props.len(), 3);
        assert_eq!(
            substance(&props),
            vec![
                ("solution".into(), "HOOK", 1),
                ("novelty".into(), "HOOK", 1),
                ("offer_strength".into(), "CVR", 1),
            ]
        );
        for p in &props {
            assert_eq!(p.kind, "pin_suggestion");
            assert_eq!(p.by, "s_creative_650");
            assert_eq!(p.stage, "PROBLEM");
            assert_eq!(p.claimed_confidence_x1000, 845); // 650*1300/1000
            assert_eq!(p.rationale, "hunch: untested territory");
            assert!(grade_against_truth(p)); // all three grade=true
        }
    }

    #[test]
    fn case_b_bias_moves_only_the_claim_matches_luajit() {
        let noted = ["urgency", "problem"];
        let mut hot = Strategist::new(7, hire("s_analytical_600", 1300, "analytical", 600));
        let mut cold = Strategist::new(7, hire("s_analytical_600", 800, "analytical", 600));
        let ph = hot.propose(&Ctx { stage: "PROBLEM", noted_aspects: &noted, count: 5 });
        let pc = cold.propose(&Ctx { stage: "PROBLEM", noted_aspects: &noted, count: 5 });

        let expected = vec![
            ("urgency".to_string(), "CTR", 1),
            ("urgency".to_string(), "CTR", -1),
            ("problem".to_string(), "HOOK", -1),
            ("urgency".to_string(), "CTR", 1),
            ("problem".to_string(), "HOOK", -1),
        ];
        // identical substance, same seed+skill, different bias (LAW 2)
        assert_eq!(substance(&ph), expected);
        assert_eq!(substance(&pc), expected);
        for p in &ph {
            assert_eq!(p.claimed_confidence_x1000, 780); // 600*1300/1000
            assert_eq!(p.rationale, "pattern-adjacent: builds on the ledger");
        }
        for p in &pc {
            assert_eq!(p.claimed_confidence_x1000, 480); // 600*800/1000
        }
        // only the claimed confidence differs
        assert!(ph[0].claimed_confidence_x1000 > pc[0].claimed_confidence_x1000);
    }

    #[test]
    fn case_c_product_empty_ledger_matches_luajit() {
        let noted: [&str; 0] = [];
        let mut s = Strategist::new(1, hire("s_analytical_600", 1300, "analytical", 600));
        let props = s.propose(&Ctx { stage: "PRODUCT", noted_aspects: &noted, count: 10 });
        assert_eq!(
            substance(&props),
            vec![
                ("novelty".into(), "HOOK", 1),
                ("solution".into(), "HOOK", 1),
                ("novelty".into(), "HOOK", -1),
                ("mechanism".into(), "HOOK", -1),
                ("comparison".into(), "HOOK", 1),
                ("mechanism".into(), "HOOK", -1),
                ("solution".into(), "HOOK", -1),
                ("offer_strength".into(), "CVR", -1),
                ("mechanism".into(), "HOOK", 1),
                ("novelty".into(), "HOOK", 1),
            ]
        );
        for p in &props {
            assert_eq!(p.claimed_confidence_x1000, 780);
            assert_eq!(p.stage, "PRODUCT");
        }
    }

    #[test]
    fn case_d_creative_explores_matches_luajit() {
        let noted = ["urgency", "problem"];
        let mut s = Strategist::new(11, hire("s_creative_600", 1000, "creative", 600));
        let props = s.propose(&Ctx { stage: "PROBLEM", noted_aspects: &noted, count: 20 });
        // full aspect+direction sequence from luajit
        assert_eq!(
            substance(&props),
            vec![
                ("solution".into(), "HOOK", 1),
                ("trust".into(), "CVR", -1),
                ("solution".into(), "HOOK", -1),
                ("novelty".into(), "HOOK", -1),
                ("mechanism".into(), "HOOK", -1),
                ("offer_strength".into(), "CVR", -1),
                ("trust".into(), "CVR", -1),
                ("urgency".into(), "CTR", -1),
                ("solution".into(), "HOOK", -1),
                ("solution".into(), "HOOK", 1),
                ("mechanism".into(), "HOOK", 1),
                ("scarcity".into(), "HOOK", -1),
                ("mechanism".into(), "HOOK", 1),
                ("mechanism".into(), "HOOK", -1),
                ("mechanism".into(), "HOOK", 1),
                ("mechanism".into(), "HOOK", -1),
                ("problem".into(), "HOOK", 1),
                ("novelty".into(), "HOOK", -1),
                ("novelty".into(), "HOOK", 1),
                ("trust".into(), "CVR", 1),
            ]
        );
        // creative explores: >=70% novel (not urgency/problem) aspects
        let novel = props
            .iter()
            .filter(|p| p.aspect != "urgency" && p.aspect != "problem")
            .count();
        assert!(novel >= 14, "novel share {} >= 14/20", novel);
    }

    #[test]
    fn track_record_matches_luajit() {
        let mut s = Strategist::new(5, hire("s_creative_650", 1300, "creative", 650));
        s.record_grade("CONFIRMED");
        s.record_grade("BUSTED");
        s.record_grade("INCONCLUSIVE"); // ignored
        s.record_grade("CONFIRMED");
        assert_eq!(
            s.track_record(),
            TrackRecord { graded: 3, hits: 2, hit_rate_x1000: 666 } // floor(1000*2/3)
        );
        // empty ledger -> rate 0, no divide-by-zero
        let fresh = Strategist::new(5, hire("z", 1000, "creative", 600));
        assert_eq!(
            fresh.track_record(),
            TrackRecord { graded: 0, hits: 0, hit_rate_x1000: 0 }
        );
    }
}
