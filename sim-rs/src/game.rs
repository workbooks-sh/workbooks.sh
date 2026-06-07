//! Run/compose orchestrator. Faithful port of sim/game.lua (the integration
//! layer, ad-7r3.11): one headless engagement wiring EVERY system —
//! content -> resonance -> fatigue -> composer -> wave machine -> economy ->
//! team -> ledger -> director -> shimmer — so the systems are proven to compose
//! before any engine work. Bots (sim/bots.lua) supply decisions; this module
//! owns the plumbing.
//!
//! Integration simplifications (documented, revisit post-slice), carried over
//! verbatim from the Lua:
//!   - director effects bake as flight-averaged cpm (time-varying rates need a
//!     wave-machine hook later) — here the schedule is built but not yet read
//!     into the flight, exactly as the Lua leaves it;
//!   - per-ad wear = average of member-card wear mults on the lane;
//!   - shimmer is exercised via per-ad calibration states (no mid-flight truth
//!     changes yet); hold-side wear deferred (FINDINGS #3).
//!
//! Determinism is sacred: the rng call ORDER/COUNT mirrors the Lua exactly —
//! compose builds the resonance lane lazily (its own substream), the wave
//! machine owns per-ad substreams, the director and economy each draw from
//! their own. Money is integer cents; probabilities integer ppm; the few
//! `math.floor(a*b/1000)` paths are i64 truncating division (operands are
//! non-negative, so floor == truncation). Cross-validated vs luajit goldens
//! (see #[cfg(test)] / /tmp/game_golden.lua).

use crate::{composer, content, director, economy, fatigue, funnel, ledger, resonance, shimmer, team, wave};
use std::collections::HashMap;

// ----------------------------------------------------------------- constants

/// Layer-1 baseline funnel truth before resonance/fatigue/overload (mirrors
/// Game.BASE_TRUTH). Consumed by `resonance::apply`.
pub const BASE_TRUTH: resonance::BaseTruth = resonance::BaseTruth {
    hook_ppm: 240000,
    hold_given_stop_ppm: Some(450000),
    click_given_stop_ppm: 170000,
    cvr_ppm: 24000,
    aov_cents: 4500,
};
pub const AD_BUDGET_CENTS: i64 = 40000;
pub const CAPACITY: i64 = 6;
pub const BASE_BUILDS: i64 = 2;

// ----------------------------------------------------------------- data shape

/// Run-scoped counters (mirrors g.stats).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub calibrated_ads: i64,
    pub launched_ads: i64,
    pub director_events: i64,
    pub packs_opened: i64,
    pub last_pack: Vec<String>,
}

/// A pack lane plus its lazily-built per-client resonance weights (mirrors the
/// Lua `g.lanes[id] = { def, rlane, client }`).
#[derive(Clone)]
pub struct LaneSlot {
    pub def: content::Lane,
    pub rlane: Option<resonance::Lane>,
    pub client: Option<String>,
}

/// A composed, launchable ad (mirrors the table Game.compose returns). `truth`
/// is the overload-applied composer truth; convert to a funnel truth at launch.
#[derive(Clone, Debug)]
pub struct Spec {
    pub truth: composer::Truth,
    pub cards: Vec<composer::Card>,
    pub card_ids: Vec<String>,
    pub fatigue_rate_x1000: i64,
}

/// One build choice: which cards, and whether it's a clean test (mirrors the
/// Lua `{ card_ids, clean }`).
#[derive(Clone, Debug)]
pub struct Pick {
    pub card_ids: Vec<String>,
    pub clean: Option<bool>,
}

/// The attributed claim a pin tests (mirrors `pin.claim = { aspect, direction }`).
#[derive(Clone, Debug)]
pub struct Claim {
    pub aspect: String,
    pub direction: i32,
}

/// One A/B pin (mirrors `{ a, b, metric, call, claim }`). a/b/call are 1-based
/// ad indices; metric is "HOOK"/"CTR"/"CVR".
#[derive(Clone, Debug)]
pub struct PinSpec {
    pub a: usize,
    pub b: usize,
    pub metric: String,
    pub call: usize,
    pub claim: Option<Claim>,
}

/// The whole engagement state (mirrors the `g` table).
pub struct Game {
    pub seed: u32,
    pub pack: content::Content,
    pub cards: HashMap<String, content::Card>,
    pub lanes: HashMap<String, LaneSlot>,
    pub bank: economy::Bank,
    pub collection: economy::Collection,
    pub desk: team::Desk,
    pub ledger: ledger::RunLedger,
    pub combo_book: composer::ComboBook,
    pub wear: HashMap<String, HashMap<String, fatigue::Wear>>,
    pub stats: Stats,
    pub run: wave::Run,
}

pub use crate::demo::demo_pack;

// --------------------------------------------------------------- construction

pub fn new(seed: u32, pack: content::Content) -> Game {
    let mut cards = HashMap::new();
    let mut collection = economy::new_collection();
    for c in &pack.cards {
        cards.insert(c.id.clone(), c.clone());
        collection.owned.insert(c.id.clone());
    }
    let mut lanes = HashMap::new();
    let mut wear = HashMap::new();
    for l in &pack.lanes {
        lanes.insert(l.id.clone(), LaneSlot { def: l.clone(), rlane: None, client: None });
        wear.insert(l.id.clone(), HashMap::new());
    }
    let clients: Vec<wave::Client> = pack
        .clients
        .iter()
        .map(|c| wave::Client {
            id: c.id.clone(),
            multiples: c.multiples.clone(),
            base_target_cents: c.base_target_cents,
            spend_floor_cents: c.spend_floor_cents,
            fee_cents: c.fee_cents,
        })
        .collect();
    let run = wave::new_run(wave::Cfg {
        seed,
        clients,
        pips: Some(3),
        ap_per_day: None,
        flight_cfg: wave::FlightCfg {
            cpm_cents: 1200,
            days: 5,
            seconds_per_day: 36,
            ticks_per_second: 10,
            day_mods: None,
        },
    });
    Game {
        seed,
        pack,
        cards,
        lanes,
        bank: economy::new_bank(60000),
        collection,
        desk: team::new_desk(2),
        ledger: ledger::new_run_ledger(),
        combo_book: composer::new_combo_book(),
        wear,
        stats: Stats::default(),
        run,
    }
}

pub fn current_client(g: &Game) -> &content::Client {
    &g.pack.clients[g.run.client_i - 1]
}

/// Ensure the current client's lane has its hidden resonance weights built
/// (lazy, per (run, client) — mirrors Game.current_lane). Returns the lane id.
fn ensure_current_lane(g: &mut Game) -> String {
    let seed = g.seed;
    let ci = g.run.client_i;
    let (client_id, lane_id) = {
        let client = &g.pack.clients[ci - 1];
        (client.id.clone(), client.lane.clone().expect("client has a lane"))
    };
    let slot = g.lanes.get_mut(&lane_id).expect("lane exists in pack");
    let stale = slot.client.as_deref() != Some(client_id.as_str());
    if slot.rlane.is_none() || stale {
        let stage = slot.def.stage.clone();
        slot.rlane = Some(resonance::new_lane(seed, &client_id, &stage));
        slot.client = Some(client_id);
    }
    lane_id
}

fn wear_for<'a>(g: &'a mut Game, lane_id: &str, card_id: &str) -> &'a mut fatigue::Wear {
    g.wear
        .get_mut(lane_id)
        .expect("lane wear map exists")
        .entry(card_id.to_string())
        .or_insert_with(fatigue::new_wear)
}

/// Wear status is PUBLIC player knowledge (the in-game VHS-noise/status chips).
/// Mirrors Game.wear_status: "FRESH" when untouched, else the fatigue status.
pub fn wear_status(g: &mut Game, card_id: &str) -> &'static str {
    let lane_id = ensure_current_lane(g);
    match g.wear.get(&lane_id).and_then(|m| m.get(card_id)) {
        Some(w) => fatigue::status(w),
        None => "FRESH",
    }
}

fn to_funnel_truth(t: &composer::Truth) -> funnel::Truth {
    funnel::Truth {
        hook_ppm: t.hook_ppm as u32,
        hold_given_stop_ppm: t.hold_given_stop_ppm.map(|h| h as u32),
        click_given_stop_ppm: t.click_given_stop_ppm as u32,
        cvr_ppm: t.cvr_ppm as u32,
        aov_cents: t.aov_cents as u64,
    }
}

fn economy_pool(pack: &content::Content) -> Vec<economy::Card> {
    pack.cards
        .iter()
        .map(|c| economy::Card {
            id: c.id.clone(),
            rarity: c.rarity.clone(),
            aspects: c.aspects.iter().map(|a| economy::Aspect { name: a.name.clone(), pts: a.pts }).collect(),
            foil: false,
        })
        .collect()
}

// --------------------------------------------------------------- compose

/// Compose card ids into a launchable truth on the current lane. Mirrors
/// Game.compose exactly (resonance score+apply, flight-flat wear averaging,
/// overload legibility, combo-echo fatigue rate).
pub fn compose(g: &mut Game, card_ids: &[String]) -> Spec {
    let lane_id = ensure_current_lane(g);
    let rlane = g.lanes[&lane_id].rlane.clone().expect("rlane initialized");

    // summed aspect vector (canonical order) + composer cards, in card order.
    let mut vec = [0i64; 10];
    let mut cards: Vec<composer::Card> = Vec::with_capacity(card_ids.len());
    for id in card_ids {
        let c = g.cards.get(id).expect("card id exists in pack");
        cards.push(composer::Card { id: c.id.clone(), weight: c.weight });
        for a in &c.aspects {
            if let Some(i) = resonance::aspect_index(&a.name) {
                vec[i] += a.pts;
            }
        }
    }

    let mods = resonance::score(&rlane, &vec);
    let applied = resonance::apply(&BASE_TRUTH, &mods);

    // average member wear on this lane.
    let (mut hsum, mut csum, mut vsum) = (0i64, 0i64, 0i64);
    for c in &cards {
        let m = fatigue::mults(wear_for(g, &lane_id, &c.id));
        hsum += m.hook_x1000;
        csum += m.ctr_x1000;
        vsum += m.cvr_x1000;
    }
    let n = cards.len() as i64;

    // shape only: zero-wear apply_to_truth is identity, but reshapes to a
    // funnel truth (drops the fatigue rate) just as the Lua does.
    let mut ft = fatigue::apply_to_truth(
        &fatigue::Truth {
            hook_ppm: applied.hook_ppm as i64,
            hold_given_stop_ppm: applied.hold_given_stop_ppm.map(|h| h as i64),
            click_given_stop_ppm: applied.click_given_stop_ppm as i64,
            cvr_ppm: applied.cvr_ppm as i64,
            aov_cents: applied.aov_cents as i64,
        },
        &fatigue::Wear { freq_x1000: 0, scars: 0, in_cycle: false },
    );
    ft.hook_ppm = ft.hook_ppm * (hsum / n) / 1000;
    ft.click_given_stop_ppm = ft.click_given_stop_ppm * (csum / n) / 1000;
    ft.cvr_ppm = ft.cvr_ppm * (vsum / n) / 1000;

    // overload penalty (hook + hold legibility only).
    let over = composer::over_by(&cards, CAPACITY);
    let truth = composer::apply_overload(
        &composer::Truth {
            hook_ppm: ft.hook_ppm,
            hold_given_stop_ppm: ft.hold_given_stop_ppm,
            click_given_stop_ppm: ft.click_given_stop_ppm,
            cvr_ppm: ft.cvr_ppm,
            aov_cents: ft.aov_cents,
        },
        over,
    );

    let combo_rate = composer::combo_rate_x1000(&g.combo_book, &cards);
    let fatigue_rate_x1000 = composer::total_fatigue_rate_x1000(mods.fatigue_rate_x1000, combo_rate);

    Spec { truth, cards, card_ids: card_ids.to_vec(), fatigue_rate_x1000 }
}

// --------------------------------------------------------------- play_wave

/// Compose one pick and issue its launch command (legal in BUILD or mid-FLIGHT).
/// Returns whether the wave machine accepted the launch, plus the computed spec
/// (always computed). Shared by `play_wave` and the dashboard bridge so the
/// compose-then-launch path has a single home. In BUILD the launch always
/// succeeds (so `play_wave`'s behaviour is unchanged); mid-flight it can be
/// refused (too late in the week, or out of attention).
pub fn compose_and_launch(g: &mut Game, pick: &Pick) -> (bool, Spec) {
    let spec = compose(g, &pick.card_ids);
    let truth = to_funnel_truth(&spec.truth);
    let ok = wave::command(
        &mut g.run,
        &wave::Command {
            kind: "launch".into(),
            truth: Some(truth),
            budget_cents: Some(AD_BUDGET_CENTS),
            clean: pick.clean,
            ..Default::default()
        },
    );
    if ok {
        g.stats.launched_ads += 1;
    }
    (ok, spec)
}

/// Build the director schedule (flight-averaged cpm bake — the documented
/// integration simplification) and issue `go`. Returns whether the flight
/// started. Mirrors the schedule+go step of Game.play_wave.
pub fn begin_flight(g: &mut Game) -> bool {
    let sched = director::new_schedule(g.seed, g.run.global_wave as u32, 1800, 360);
    g.stats.director_events += sched.events.len() as i64;
    wave::command(&mut g.run, &wave::Command::new("go"))
}

/// Settle a finished flight at the game level: post-flight bookkeeping (wear,
/// combos, shimmer), ledger pin grading, and economy (payout/recovery, payroll,
/// interest, optional pack). Returns the run result and per-ad revenue (cents).
/// Does NOT leave the newsstand — the caller advances the wave when ready (the
/// Lua's shop_done/skip_shop handshake). Mirrors the tail of Game.play_wave.
pub fn settle_wave(
    g: &mut Game,
    specs: &[Spec],
    pins: &[PinSpec],
    buy_pack: bool,
) -> (wave::RunResult, Vec<i64>) {
    let result = g.run.last_result.clone().expect("autopsy set last_result");

    // bookkeeping: wear, combos, shimmer, ledger, money
    let lane_id = ensure_current_lane(g);
    let audience = g.lanes[&lane_id].def.audience;
    let stage = g.lanes[&lane_id].def.stage.clone();

    for (i, spec) in specs.iter().enumerate() {
        let (ad_imps, ad_buys) = {
            let ad = g.run.ad_counts(i + 1);
            (ad.imps as i64, ad.buys)
        };
        for c in &spec.cards {
            let w = wear_for(g, &lane_id, &c.id);
            fatigue::expose(w, ad_imps, audience, spec.fatigue_rate_x1000);
        }
        composer::combo_used(&mut g.combo_book, &spec.cards);
        let mut sh = shimmer::new_state();
        for _ in 0..ad_buys {
            shimmer::on_conversion(&mut sh);
        }
        if shimmer::is_calibrated(&sh) {
            g.stats.calibrated_ads += 1;
        }
    }

    for (j, pin) in pins.iter().enumerate() {
        if let (Some(graded), Some(claim)) = (result.pins.get(j), pin.claim.as_ref()) {
            let verdict = graded.verdict.clone().unwrap_or_else(|| "INCONCLUSIVE".into());
            ledger::record_pin(
                &mut g.ledger,
                &ledger::Pin {
                    verdict,
                    clean: true,
                    aspect: claim.aspect.clone(),
                    stage: stage.clone(),
                    metric: pin.metric.clone(),
                    direction: claim.direction,
                },
            );
        }
    }

    economy::earn(&mut g.bank, result.payout_cents + result.recovered_cents);
    team::pay_wave(&g.desk, &mut g.bank.cents);
    economy::apply_interest(&mut g.bank);
    if buy_pack && g.bank.cents > 70000 {
        let pack_seed = g.seed.wrapping_mul(100).wrapping_add(g.run.global_wave as u32);
        let pool = economy_pool(&g.pack);
        if let Some(cards) = economy::open_pack(&mut g.bank, &mut g.collection, pack_seed, &pool) {
            g.stats.packs_opened += 1;
            g.stats.last_pack = cards.iter().map(|c| c.id.clone()).collect();
        }
    }

    let mut revs: Vec<i64> = Vec::with_capacity(g.run.ad_count());
    for i in 1..=g.run.ad_count() {
        revs.push(g.run.ad_counts(i).revenue_cents as i64);
    }

    (result, revs)
}

/// Play one full wave. `picks` are build choices, `pins` are A/B tests. Returns
/// the run result and per-ad revenue (cents). Mirrors Game.play_wave.
pub fn play_wave(
    g: &mut Game,
    picks: &[Pick],
    pins: &[PinSpec],
    buy_pack: bool,
) -> (wave::RunResult, Vec<i64>) {
    wave::command(&mut g.run, &wave::Command::new("ack_brief"));

    let mut specs: Vec<Spec> = Vec::with_capacity(picks.len());
    for p in picks {
        let (_ok, spec) = compose_and_launch(g, p);
        specs.push(spec);
    }

    for pin in pins {
        wave::command(
            &mut g.run,
            &wave::Command {
                kind: "pin".into(),
                a: Some(pin.a),
                b: Some(pin.b),
                metric: Some(pin.metric.clone()),
                call: Some(pin.call),
                ..Default::default()
            },
        );
    }

    begin_flight(g);
    wave::advance(&mut g.run, 99999);
    let out = settle_wave(g, &specs, pins, buy_pack);

    if g.run.state == "NEWSSTAND" {
        wave::command(&mut g.run, &wave::Command::new("skip_shop"));
    }

    out
}

// --------------------------------------------------------------- tests

#[cfg(test)]
mod tests;
