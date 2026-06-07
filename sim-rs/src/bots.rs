//! Policy bots for the integration run (ad-7r3.11): three players for the same
//! seeded worlds. Faithful port of sim/bots.lua.
//!
//! RANDOM ignores everything; HEURISTIC tests cleanly, listens to a hired
//! strategist, and exploits observed winners while dodging echo; ORACLE composes
//! with perfect knowledge (game::compose reveals the truth to it) and rotates
//! around wear automatically by re-ranking each wave.
//!
//! Determinism: the rng call ORDER/COUNT mirrors the Lua exactly. RANDOM draws
//! hook,visual,format per ad (6 draws/wave, in that order); HEURISTIC draws only
//! through the strategist substream; ORACLE draws nothing (it reads compose()).
//! The ORACLE ranking deliberately mirrors the Lua's f64 score
//! `(hook/1e6)*(click/1e6)*cvr` — that is the BOT POLICY, not sim truth (IEEE-754
//! mul/div are correctly-rounded, so it matches LuaJIT bit-for-bit; cross-checked
//! to have no boundary ties over the integration seeds). Money is integer cents.
use crate::rng::Rng;
use crate::{composer, game, strategist, team};

// ---------------------------------------------------------------- helpers

/// Owned card-id buckets by kind for the current owned collection (mirrors the
/// Lua `by_kind`: iterate pack.cards in order, keep owned ids per kind).
struct ByKind {
    hook: Vec<String>,
    visual: Vec<String>,
    format: Vec<String>,
    #[allow(dead_code)]
    offer: Vec<String>, // collected for fidelity; no policy reads it
}

fn by_kind(g: &game::Game) -> ByKind {
    let mut k = ByKind { hook: Vec::new(), visual: Vec::new(), format: Vec::new(), offer: Vec::new() };
    for c in &g.pack.cards {
        if g.collection.owned.contains(&c.id) {
            match c.kind.as_str() {
                "hook" => k.hook.push(c.id.clone()),
                "visual" => k.visual.push(c.id.clone()),
                "format" => k.format.push(c.id.clone()),
                "offer" => k.offer.push(c.id.clone()),
                _ => {}
            }
        }
    }
    k
}

fn all_combos(g: &game::Game) -> Vec<Vec<String>> {
    let k = by_kind(g);
    let mut combos = Vec::new();
    for h in &k.hook {
        for v in &k.visual {
            for f in &k.format {
                combos.push(vec![h.clone(), v.clone(), f.clone()]);
            }
        }
    }
    combos
}

// ---------------------------------------------------------------- policies

fn pick(rng: &mut Rng, list: &[String]) -> String {
    // Lua `list[1 + rng:next_u32() % #list]` -> 0-based index, one draw.
    list[(rng.next_u32() % list.len() as u32) as usize].clone()
}

fn random_picks(g: &game::Game, rng: &mut Rng) -> (Vec<game::Pick>, Vec<game::PinSpec>) {
    let k = by_kind(g);
    let mut picks = Vec::with_capacity(2);
    for _ in 0..2 {
        // draw order is load-bearing: hook, then visual, then format.
        let h = pick(rng, &k.hook);
        let v = pick(rng, &k.visual);
        let f = pick(rng, &k.format);
        picks.push(game::Pick { card_ids: vec![h, v, f], clean: None });
    }
    (picks, Vec::new())
}

fn oracle_picks(g: &mut game::Game) -> (Vec<game::Pick>, Vec<game::PinSpec>) {
    let combos = all_combos(g);
    let mut scored: Vec<(Vec<String>, f64)> = Vec::with_capacity(combos.len());
    for ids in combos {
        let t = game::compose(g, &ids).truth;
        // revenue-greedy: the full projected chain, not just the hook. Mirrors
        // the Lua float score exactly (the bot's ranking, not a sim truth path).
        let score = (t.hook_ppm as f64 / 1e6)
            * (t.click_given_stop_ppm as f64 / 1e6)
            * (t.cvr_ppm as f64);
        scored.push((ids, score));
    }
    // descending by score == Lua `score[a] > score[b]`. Stable sort preserves the
    // all_combos order for (improbable, verified-absent) ties.
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let first = scored[0].0.clone();
    let second = scored[1].0.clone();
    (
        vec![
            game::Pick { card_ids: first, clean: None },
            game::Pick { card_ids: second, clean: None },
        ],
        Vec::new(),
    )
}

/// First fresh card of the bucket that isn't `exclude_id`; falls back to
/// `exclude_id` (mirrors the Lua `fresh_same_kind`).
fn fresh_same_kind(g: &mut game::Game, bucket: &[String], exclude_id: &str) -> String {
    for id in bucket {
        if id != exclude_id && game::wear_status(g, id) == "FRESH" {
            return id.clone();
        }
    }
    exclude_id.to_string()
}

fn heuristic_picks(g: &mut game::Game, state: &mut State) -> (Vec<game::Pick>, Vec<game::PinSpec>) {
    // a new client is a new audience: retest, don't carry the old pattern.
    if state.client_i != Some(g.run.client_i) {
        state.client_i = Some(g.run.client_i);
        state.best_ids = None;
    }
    let lane_id = game::current_client(g).lane.clone().expect("client has a lane");
    let stage = g.lanes[&lane_id].def.stage.clone();

    let proposals = {
        let noted: Vec<&str> = g.ledger.notes.iter().map(|n| n.aspect.as_str()).collect();
        let s = state.strategist.as_mut().expect("heuristic has a strategist");
        s.propose(&strategist::Ctx { stage: &stage, noted_aspects: &noted, count: 2 })
    };
    let k = by_kind(g);

    // base = best observed combo so far, or a proposal-guided seed.
    let mut base: Vec<String> = match &state.best_ids {
        Some(b) => b.clone(),
        None => vec![k.hook[0].clone(), k.visual[0].clone(), k.format[0].clone()],
    };
    // rest tired cards: status chips are on screen — swap any non-FRESH member.
    let kinds = ["hook", "visual", "format"];
    for i in 0..3 {
        if game::wear_status(g, &base[i]) != "FRESH" {
            let bucket = match kinds[i] {
                "hook" => &k.hook,
                "visual" => &k.visual,
                _ => &k.format,
            };
            let repl = fresh_same_kind(g, bucket, &base[i]);
            base[i] = repl;
        }
    }
    // challenger: swap the hook toward the strongest positive proposal's aspect.
    let mut target_aspect: Option<String> = None;
    for p in &proposals {
        if p.direction == 1 {
            target_aspect = Some(p.aspect.clone());
            break;
        }
    }
    let mut challenger_hook: Option<String> = None;
    for hid in &k.hook {
        if *hid != base[0] {
            if let Some(ta) = &target_aspect {
                if game::wear_status(g, hid) == "FRESH"
                    && g.cards[hid].aspects.iter().any(|a| &a.name == ta)
                {
                    challenger_hook = Some(hid.clone());
                }
            }
        }
        if challenger_hook.is_some() {
            break;
        }
    }
    if challenger_hook.is_none() {
        for hid in &k.hook {
            if *hid != base[0] && game::wear_status(g, hid) == "FRESH" {
                challenger_hook = Some(hid.clone());
                break;
            }
        }
    }
    if challenger_hook.is_none() {
        for hid in &k.hook {
            if *hid != base[0] {
                challenger_hook = Some(hid.clone());
                break;
            }
        }
    }
    // dodge echo: if the base combo is getting stale, remix the format.
    let echo_cards: Vec<composer::Card> = base
        .iter()
        .map(|id| {
            let c = &g.cards[id];
            composer::Card { id: c.id.clone(), weight: c.weight }
        })
        .collect();
    if composer::combo_rate_x1000(&g.combo_book, &echo_cards) > 1150 {
        for fid in &k.format {
            if *fid != base[2] {
                base = vec![base[0].clone(), base[1].clone(), fid.clone()];
                break;
            }
        }
    }
    let challenger_hook = challenger_hook.expect("a challenger hook is always found");
    let challenger = vec![challenger_hook.clone(), base[1].clone(), base[2].clone()];
    let claim_aspect = g.cards[&challenger_hook].aspects[0].name.clone();
    let picks = vec![
        game::Pick { card_ids: base, clean: Some(true) },
        game::Pick { card_ids: challenger, clean: Some(true) }, // differs by exactly one card
    ];
    let pins = vec![game::PinSpec {
        a: 1,
        b: 2,
        metric: "HOOK".to_string(),
        call: if target_aspect.is_some() { 2 } else { 1 },
        claim: Some(game::Claim { aspect: claim_aspect, direction: 1 }),
    }];
    (picks, pins)
}

// ---------------------------------------------------------------- driver

/// Per-run bot scratch state (mirrors the Lua `state` table). `rng` is always
/// seeded; `strategist` only exists for HEURISTIC; `client_i`/`best_ids` fill in
/// lazily inside the heuristic.
struct State {
    rng: Rng,
    strategist: Option<strategist::Strategist>,
    client_i: Option<usize>,
    best_ids: Option<Vec<String>>,
}

/// The result of one full engagement (mirrors the Lua return table). `game` is
/// handed back so callers can inspect every system's end state.
pub struct Outcome {
    pub cleared: bool,
    pub state: String,
    pub waves: i64,
    pub bank_cents: i64,
    pub game: game::Game,
}

pub fn play(policy: &str, seed: u32) -> Outcome {
    let mut g = game::new(seed, game::demo_pack());
    let mut state = State {
        rng: Rng::substream(seed, &format!("bot:{}", policy)),
        strategist: None,
        client_i: None,
        best_ids: None,
    };

    if policy == "HEURISTIC" {
        let id = "maya".to_string();
        let hire = team::HireDef {
            id: id.clone(),
            role: "creative_strategist".to_string(),
            salary_cents: 4000,
            traits: team::Traits {
                confidence_bias_x1000: 1100,
                style: "analytical".to_string(),
                skill_x1000: 700,
            },
            effects: team::Effects { info_lines: Some(1), ..Default::default() },
        };
        team::hire(&mut g.desk, &hire);
        state.strategist = Some(strategist::Strategist::new(
            seed,
            strategist::HireDef {
                id,
                traits: strategist::Traits {
                    skill_x1000: 700,
                    confidence_bias_x1000: 1100,
                    style: "analytical".to_string(),
                },
            },
        ));
    }

    while g.run.state == "BRIEF" {
        let (picks, pins) = match policy {
            "RANDOM" => random_picks(&g, &mut state.rng),
            "ORACLE" => oracle_picks(&mut g),
            _ => heuristic_picks(&mut g, &mut state),
        };

        let (result, revs) = game::play_wave(&mut g, &picks, &pins, policy == "HEURISTIC");

        if policy == "HEURISTIC" {
            // remember the better ad's combo; grade the strategist's influence.
            let r1 = revs.first().copied().unwrap_or(0);
            let r2 = revs.get(1).copied().unwrap_or(0);
            let best_i = if r2 > r1 { 1 } else { 0 };
            state.best_ids = Some(picks[best_i].card_ids.clone());
            if let Some(p) = result.pins.first() {
                let verdict = p.verdict.clone().unwrap_or_else(|| "INCONCLUSIVE".to_string());
                state.strategist.as_mut().unwrap().record_grade(&verdict);
            }
        }
    }

    Outcome {
        cleared: g.run.state == "RUN_WON",
        state: g.run.state.clone(),
        waves: g.run.global_wave,
        bank_cents: g.bank.cents,
        game: g,
    }
}

#[cfg(test)]
mod tests;
