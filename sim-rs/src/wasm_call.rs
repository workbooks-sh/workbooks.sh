//! WRI call bridge — `call(name, argsJson) -> String`.
//! Typed dispatch via serde_json. Commands: "team_pool", "strategist_propose".
use wasm_bindgen::prelude::*;
use serde::{Deserialize, Serialize};
use crate::rng::Rng;
use crate::strategist;

fn esc(s: &str) -> String { s.replace('\\', "\\\\").replace('"', "\\\"") }

// Tier parameters mirror the JS mock tiers (costs in cents).
// Weights: 50% common / 36% mid / 14% rare (cumulative: <50 / <86 / else).
struct Tier { cost_lo: i64, cost_hi: i64, skill_lo: i64, skill_hi: i64 }
const TIERS: [Tier; 3] = [
    Tier { cost_lo: 18000, cost_hi: 26000, skill_lo: 300, skill_hi: 620 },
    Tier { cost_lo: 28000, cost_hi: 36000, skill_lo: 480, skill_hi: 780 },
    Tier { cost_lo: 38000, cost_hi: 44000, skill_lo: 660, skill_hi: 920 },
];
const STYLES: [&str; 4] = ["creative", "analytical", "fastmover", "meticulous"];

fn pick_tier(r: u32) -> usize {
    let v = r % 100;
    if v < 50 { 0 } else if v < 86 { 1 } else { 2 }
}
fn rand_range(lo: i64, hi: i64, r: u32) -> i64 {
    lo + (r as i64 % (hi - lo + 1))
}

#[derive(Serialize)]
struct CandidateOut {
    id: String,
    role: String,
    style: String,
    skill_x1000: i64,
    confidence_bias_x1000: i64,
    cost_cents: i64,
    salary_cents: i64,
}

#[derive(Deserialize)]
struct TeamPoolArgs { seed: u32, count: u32 }

fn gen_team_pool(seed: u32, count: u32) -> Vec<CandidateOut> {
    let roles = ["strategist", "media"];
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut r = Rng::substream(seed, &format!("cand:{}", i));
        let ti = pick_tier(r.next_u32());
        let t = &TIERS[ti];
        let cost = rand_range(t.cost_lo, t.cost_hi, r.next_u32());
        let skill = rand_range(t.skill_lo, t.skill_hi, r.next_u32());
        let bias = rand_range(800, 1400, r.next_u32());
        let style = STYLES[(r.next_u32() % STYLES.len() as u32) as usize].to_string();
        let id = format!("{:08x}", r.next_u32());
        out.push(CandidateOut {
            id,
            role: roles[(i % 2) as usize].into(),
            style,
            skill_x1000: skill,
            confidence_bias_x1000: bias,
            cost_cents: cost,
            salary_cents: cost / 4 / 100 * 100,
        });
    }
    out
}

#[derive(Deserialize)]
struct HireRef {
    id: String,
    style: String,
    skill_x1000: i64,
    confidence_bias_x1000: i64,
}

#[derive(Deserialize)]
struct StrategistProposeArgs {
    seed: u32,
    stage: String,
    noted_aspects: Vec<String>,
    count: u32,
    hires: Vec<HireRef>,
}

#[derive(Serialize)]
struct ProposalOut {
    kind: String,
    by: String,
    aspect: String,
    stage: String,
    metric: String,
    direction: i64,
    claimed_confidence_x1000: i64,
    rationale: String,
}

fn gen_proposals(args: StrategistProposeArgs) -> Vec<ProposalOut> {
    let noted: Vec<&str> = args.noted_aspects.iter().map(|s| s.as_str()).collect();
    let ctx = strategist::Ctx {
        stage: &args.stage,
        noted_aspects: &noted,
        count: args.count,
    };
    let mut out = Vec::new();
    for hire in &args.hires {
        let hdef = strategist::HireDef {
            id: hire.id.clone(),
            traits: strategist::Traits {
                skill_x1000: hire.skill_x1000,
                confidence_bias_x1000: hire.confidence_bias_x1000,
                style: hire.style.clone(),
            },
        };
        let mut s = strategist::Strategist::new(args.seed, hdef);
        for p in s.propose(&ctx) {
            out.push(ProposalOut {
                kind: p.kind.into(),
                by: p.by,
                aspect: p.aspect,
                stage: p.stage,
                metric: p.metric.into(),
                direction: p.direction,
                claimed_confidence_x1000: p.claimed_confidence_x1000,
                rationale: p.rationale.into(),
            });
        }
    }
    out
}

/// WRI universal dispatcher: call(name, argsJson) -> JSON string.
/// Commands: "team_pool" {seed,count}, "strategist_propose" {seed,stage,noted_aspects,count,hires}.
#[wasm_bindgen]
pub fn call(name: &str, args_json: &str) -> String {
    match name {
        "team_pool" => match serde_json::from_str::<TeamPoolArgs>(args_json) {
            Ok(a) => serde_json::to_string(&gen_team_pool(a.seed, a.count)).unwrap_or_else(|_| "[]".into()),
            Err(e) => format!("{{\"error\":\"{}\"}}", e),
        },
        "strategist_propose" => match serde_json::from_str::<StrategistProposeArgs>(args_json) {
            Ok(a) => serde_json::to_string(&gen_proposals(a)).unwrap_or_else(|_| "[]".into()),
            Err(e) => format!("{{\"error\":\"{}\"}}", e),
        },
        _ => format!("{{\"error\":\"unknown: {}\"}}", esc(name)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn team_pool_alternating_roles() {
        let json = call("team_pool", r#"{"seed":42,"count":4}"#);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let arr = v.as_array().unwrap();
        assert_eq!(arr.len(), 4);
        assert_eq!(arr[0]["role"], "strategist");
        assert_eq!(arr[1]["role"], "media");
        assert_eq!(arr[2]["role"], "strategist");
        assert_eq!(arr[3]["role"], "media");
        assert!(arr[0]["cost_cents"].as_i64().unwrap() > 0);
        assert!(arr[0]["skill_x1000"].as_i64().unwrap() >= 300);
    }

    #[test]
    fn team_pool_is_deterministic() {
        let a = call("team_pool", r#"{"seed":7,"count":8}"#);
        let b = call("team_pool", r#"{"seed":7,"count":8}"#);
        assert_eq!(a, b);
    }

    #[test]
    fn strategist_propose_returns_proposals() {
        let args = r#"{"seed":42,"stage":"PROBLEM","noted_aspects":[],"count":2,"hires":[{"id":"s1","style":"creative","skill_x1000":650,"confidence_bias_x1000":1300}]}"#;
        let json = call("strategist_propose", args);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let arr = v.as_array().unwrap();
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["kind"], "pin_suggestion");
        assert!(arr[0]["aspect"].as_str().is_some());
        assert_eq!(arr[0]["direction"].as_i64().unwrap().abs(), 1);
    }

    #[test]
    fn unknown_command_returns_error() {
        let out = call("nonexistent", "{}");
        assert!(out.contains("error"));
    }
}
