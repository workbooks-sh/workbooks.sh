//! Wave state machine (docs/01-game-design.md §1-2). Faithful port of sim/wave.lua.
//!
//! BRIEF -> BUILD -> FLIGHT -> AUTOPSY -> NEWSSTAND, headless. All player input
//! arrives as COMMANDS: journaled with the tick they were issued at and consumed
//! at tick boundaries — seed + journal IS the replay/debug system (docs/02-technical.md §4).
//! Trust pips with process protection, boss hard gates on each client's final wave,
//! free KILL with budget recovery, Pins graded through the significance engine.
//!
//! Two delivery paths, chosen per ad:
//!   LEGACY impression-Bresenham — build-phase ads without weekday modifiers;
//!   bit-identical to the original (golden fixture + published numbers safe).
//!   SPEND-PACED — ads with day modifiers or a mid-flight start.
//!
//! Integer-only deterministic state (money in cents/millicents); the rng draw
//! order is load-bearing — do not reorder anything that calls into funnel.
//!
//! Data model lives in `wave::types`; golden cross-validation in `wave::tests`.
use crate::funnel::{Ad, Truth};
use crate::rng::Rng;

mod types;
pub use types::*;

#[cfg(test)]
mod tests;

// family alpha 0.05 over 10 looks -> per-look two-sided 0.005 (spike 0a locked).
// Sig.zcrit(0.005) == 2.80703 (asserted in tests against significance::zcrit).
const Z: f64 = 2.80703;
const N_MIN: i64 = 200;

/// Lua `math.floor(a / b)` for b > 0 (rounds toward -inf; differs from Rust `/`
/// only for negatives, which `recovered_cents` can produce on cheap-CPM kills).
#[inline]
fn fdiv(a: i64, b: i64) -> i64 {
    a.div_euclid(b)
}

pub fn new_run(cfg: Cfg) -> Run {
    let pips = cfg.pips.unwrap_or(3);
    let ap = cfg.ap_per_day;
    let seed = cfg.seed;
    Run {
        cfg,
        seed,
        client_i: 1,
        wave_in_client: 1,
        global_wave: 1,
        pips,
        ap,
        state: "BRIEF".to_string(),
        journal: Vec::new(),
        builds: Vec::new(),
        pins: Vec::new(),
        clean_test_count: 0,
        ads: Vec::new(),
        tick: 0,
        plan_ticks: 0,
        ticks_per_day: 0,
        pending: Vec::new(),
        last_result: None,
    }
}

// AP cost table — enforced only when cfg.ap_per_day is set (launches cost
// attention; kill and pin stay free, always).
fn ap_ok(run: &mut Run, cmd_type: &str) -> bool {
    if run.cfg.ap_per_day.is_none() {
        return true;
    }
    let cost = if cmd_type == "launch" { 1 } else { 0 };
    if cost == 0 {
        return true;
    }
    let ap = run.ap.unwrap_or(0);
    if ap < cost {
        return false;
    }
    run.ap = Some(ap - cost);
    true
}

pub fn brief(run: &Run) -> Brief {
    let client = &run.cfg.clients[run.client_i - 1];
    let mult = client.multiples[run.wave_in_client - 1];
    Brief {
        client: client.id.clone(),
        wave_in_client: run.wave_in_client,
        is_boss: run.wave_in_client == client.multiples.len(),
        target_cents: client.base_target_cents * mult / 1000,
        spend_floor_cents: client.spend_floor_cents,
        fee_cents: client.fee_cents,
    }
}

fn add_ad(run: &mut Run, truth: Truth, budget_cents: i64, start_tick: i64) {
    let cpm_cents = run.cfg.flight_cfg.cpm_cents;
    let has_day_mods = run.cfg.flight_cfg.day_mods.is_some();
    let i = run.ads.len() + 1; // 1-based, for the substream name
    let rng = Rng::substream(run.seed, &format!("w{}:ad{}", run.global_wave, i));
    let ad_imps = budget_cents * 1000 / cpm_cents;
    let pace = if has_day_mods || start_tick > 0 {
        Some(Pace {
            budget_millicents: budget_cents * 1000,
            sched_prev: 0,
            spend_acc: 0,
            spent: 0,
            start_tick,
        })
    } else {
        None
    };
    run.ads.push(AdSlot {
        ad: Ad::new(truth),
        killed: false,
        rng,
        ad_imps,
        prev_cum: 0,
        pace,
    });
}

fn start_flight(run: &mut Run) -> bool {
    if run.builds.is_empty() {
        return false;
    }
    let mut total: i64 = 0;
    for b in &run.builds {
        total += b.budget_cents.unwrap_or(0);
    }
    if total < brief(run).spend_floor_cents {
        return false;
    }
    let fc = &run.cfg.flight_cfg;
    run.plan_ticks = fc.days * fc.seconds_per_day * fc.ticks_per_second;
    run.ticks_per_day = fc.seconds_per_day * fc.ticks_per_second;
    // gather (truth, budget) up front to satisfy the borrow checker (add_ad needs &mut run)
    let builds: Vec<(Truth, i64)> = run
        .builds
        .iter()
        .map(|b| (b.truth.expect("build truth"), b.budget_cents.unwrap_or(0)))
        .collect();
    run.ads = Vec::new();
    for (truth, budget) in builds {
        add_ad(run, truth, budget, 0);
    }
    run.tick = 0;
    run.pending = Vec::new();
    run.state = "FLIGHT".to_string();
    true
}

fn metric_counts(ad: &Ad, metric: &str) -> (i64, i64) {
    if metric == "HOOK" {
        return (ad.stops as i64, ad.imps as i64);
    }
    if metric == "CTR" {
        return (ad.clicks as i64, ad.imps as i64);
    }
    (ad.buys as i64, ad.clicks as i64) // CVR
}

fn autopsy(run: &mut Run, events: &mut Vec<Event>) {
    let brief = brief(run);
    let cpm_cents = run.cfg.flight_cfg.cpm_cents;
    let mut revenue: i64 = 0;
    let mut spend: i64 = 0;
    let mut recovered: i64 = 0;
    for slot in &run.ads {
        revenue += slot.ad.revenue_cents as i64;
        spend += (slot.ad.spend_millicents / 1000) as i64;
        if slot.killed {
            recovered += fdiv((slot.ad_imps - slot.ad.imps as i64) * cpm_cents, 1000);
        }
    }
    for p in &mut run.pins {
        if p.verdict.is_none() {
            p.verdict = Some("INCONCLUSIVE".to_string());
        }
    }

    let passed = revenue >= brief.target_cents;
    let protected = run.clean_test_count >= 1 && !run.pins.is_empty();
    let result = RunResult {
        passed,
        revenue_cents: revenue,
        spend_cents: spend,
        recovered_cents: recovered,
        payout_cents: if passed { brief.fee_cents } else { brief.fee_cents / 2 },
        field_note_bonus: !passed && protected,
        pins: run.pins.clone(),
        is_boss: brief.is_boss,
    };

    if !passed {
        if brief.is_boss {
            run.state = "FIRED".to_string();
        } else {
            run.pips -= 1;
            if run.pips <= 0 {
                run.state = "FIRED".to_string();
            }
        }
    }
    if run.state != "FIRED" {
        run.state = "NEWSSTAND".to_string();
    }

    run.last_result = Some(result);
    events.push(Event::Autopsy { passed, state: run.state.clone() });
}

fn advance_wave(run: &mut Run) {
    let n_mult = run.cfg.clients[run.client_i - 1].multiples.len();
    run.global_wave += 1;
    run.wave_in_client += 1;
    if run.wave_in_client > n_mult {
        run.client_i += 1;
        run.wave_in_client = 1;
    }
    if run.client_i > run.cfg.clients.len() {
        run.state = "RUN_WON".to_string();
    } else {
        run.state = "BRIEF".to_string();
    }
}

fn make_pin(cmd: &Command) -> Pin {
    Pin {
        a: cmd.a.expect("pin.a"),
        b: cmd.b.expect("pin.b"),
        metric: cmd.metric.clone().expect("pin.metric"),
        call: cmd.call.expect("pin.call"),
        verdict: None,
    }
}

/// Issue a player command. Journaled; returns false if illegal in this state.
pub fn command(run: &mut Run, cmd: &Command) -> bool {
    let t = cmd.kind.as_str();
    let mut ok = false;

    if run.state == "BRIEF" && t == "ack_brief" {
        run.builds = Vec::new();
        run.pins = Vec::new();
        run.clean_test_count = 0;
        run.state = "BUILD".to_string();
        ok = true;
    } else if run.state == "BUILD" {
        if t == "launch" {
            if ap_ok(run, "launch") {
                run.builds.push(cmd.clone());
                if cmd.clean == Some(true) {
                    run.clean_test_count += 1;
                }
                ok = true;
            }
        } else if t == "pin" {
            run.pins.push(make_pin(cmd));
            ok = true;
        } else if t == "go" {
            ok = start_flight(run);
        }
    } else if run.state == "FLIGHT" && t == "launch" {
        // turn-based loop: new ads join mid-week, pacing over the remaining days
        if run.tick < run.plan_ticks - 1 && ap_ok(run, "launch") {
            add_ad(run, cmd.truth.expect("launch truth"), cmd.budget_cents.unwrap_or(0), run.tick);
            ok = true;
        }
    } else if run.state == "FLIGHT" && t == "pin" {
        run.pins.push(make_pin(cmd));
        ok = true;
    } else if run.state == "FLIGHT" && t == "kill" {
        run.pending.push(cmd.clone()); // consumed at the next tick boundary
        ok = true;
    } else if run.state == "NEWSSTAND" && (t == "shop_done" || t == "skip_shop") {
        advance_wave(run);
        ok = true;
    }

    if ok {
        run.journal.push(Command {
            kind: t.to_string(),
            at_tick: Some(run.tick),
            wave: Some(run.global_wave),
            truth: cmd.truth,
            budget_cents: cmd.budget_cents,
            clean: cmd.clean,
            a: cmd.a,
            b: cmd.b,
            metric: cmd.metric.clone(),
            call: cmd.call,
            ad: cmd.ad,
        });
    }
    ok
}

/// Advance the live flight up to n ticks (stops early at autopsy). Returns events.
pub fn advance(run: &mut Run, n: i64) -> Vec<Event> {
    let mut events = Vec::new();
    if run.state != "FLIGHT" {
        return events;
    }

    for _ in 0..n {
        run.tick += 1;

        // consume queued kills at the tick boundary
        let pending = std::mem::take(&mut run.pending);
        for c in &pending {
            if c.kind == "kill" {
                if let Some(idx) = c.ad {
                    if idx >= 1 && idx <= run.ads.len() && !run.ads[idx - 1].killed {
                        run.ads[idx - 1].killed = true;
                        events.push(Event::Killed { ad: idx, tick: run.tick });
                    }
                }
            }
        }

        let day_idx = (run.tick - 1) / run.ticks_per_day + 1;
        let (mut vol_x1000, mut cpm_x1000): (i64, i64) = (1000, 1000);
        if let Some(dm) = &run.cfg.flight_cfg.day_mods {
            vol_x1000 = dm.volume_x1000.get((day_idx - 1) as usize).copied().unwrap_or(1000);
            cpm_x1000 = dm.cpm_x1000.get((day_idx - 1) as usize).copied().unwrap_or(1000);
        }

        let plan_ticks = run.plan_ticks;
        let cpm_cents = run.cfg.flight_cfg.cpm_cents;
        let tick = run.tick;
        for slot in run.ads.iter_mut() {
            if slot.killed {
                continue;
            }
            match slot.pace {
                None => {
                    // LEGACY path: impression-Bresenham (bit-identical to v1)
                    let cum = slot.ad_imps * tick / plan_ticks;
                    let imps = cum - slot.prev_cum;
                    slot.prev_cum = cum;
                    if imps > 0 {
                        slot.ad.sample_impressions(&mut slot.rng, imps as u64, cpm_cents as u64);
                    }
                }
                Some(ref mut pace) => {
                    if tick > pace.start_tick {
                        // SPEND-PACED path
                        let span = plan_ticks - pace.start_tick;
                        let sched = pace.budget_millicents * (tick - pace.start_tick) / span;
                        let tick_spend = (sched - pace.sched_prev) * vol_x1000 / 1000;
                        pace.sched_prev = sched;
                        let mut per_imp = cpm_cents * cpm_x1000 / 1000;
                        if per_imp < 1 {
                            per_imp = 1;
                        }
                        pace.spend_acc += tick_spend;
                        let mut imps = pace.spend_acc / per_imp;
                        let affordable = (pace.budget_millicents - pace.spent) / per_imp;
                        if imps > affordable {
                            imps = affordable;
                        }
                        if imps > 0 {
                            pace.spend_acc -= imps * per_imp;
                            pace.spent += imps * per_imp;
                            slot.ad.sample_impressions(&mut slot.rng, imps as u64, per_imp as u64);
                        }
                    }
                }
            }
        }

        if run.tick % run.ticks_per_day == 0 {
            let day = run.tick / run.ticks_per_day;
            events.push(Event::DayEnd { day });
            if run.cfg.ap_per_day.is_some() {
                run.ap = run.cfg.ap_per_day; // attention refills with the morning
            }
            // grade pins (disjoint borrow: ads read-only, pins mutated)
            let Run { ref ads, ref mut pins, .. } = *run;
            for p in pins.iter_mut() {
                if p.verdict.is_none() {
                    let (sa, na) = metric_counts(&ads[p.a - 1].ad, &p.metric);
                    let (sb, nb) = metric_counts(&ads[p.b - 1].ad, &p.metric);
                    let (w, _z) = crate::significance::compare(sa, na, sb, nb, Z, N_MIN);
                    if let Some(w) = w {
                        let winner = if w == "A" { p.a } else { p.b };
                        let verdict = if winner == p.call { "CONFIRMED" } else { "BUSTED" };
                        p.verdict = Some(verdict.to_string());
                        events.push(Event::Bell { winner, verdict: verdict.to_string(), day });
                    }
                }
            }
        }

        if run.tick >= run.plan_ticks {
            autopsy(run, &mut events);
            break;
        }
    }
    events
}

/// The turn: advance exactly one day and return its events (design/flows.md).
pub fn end_day(run: &mut Run) -> Vec<Event> {
    if run.state != "FLIGHT" {
        return Vec::new();
    }
    advance(run, run.ticks_per_day - (run.tick % run.ticks_per_day))
}

/// Deterministic state hash (FNV-1a over an ordered integer dump) — the
/// replay-guarantee primitive. Reuses rng::fnv1a (seed 0 == the Lua's bare init).
pub fn state_hash(run: &Run) -> u32 {
    let mut parts: Vec<String> = vec![
        run.state.clone(),
        run.pips.to_string(),
        run.client_i.to_string(),
        run.wave_in_client.to_string(),
        run.global_wave.to_string(),
        run.journal.len().to_string(),
        run.tick.to_string(),
    ];
    if run.cfg.ap_per_day.is_some() {
        parts.push(run.ap.unwrap_or(0).to_string()); // legacy hashes untouched
    }
    if let Some(r) = &run.last_result {
        parts.push(if r.passed { "1" } else { "0" }.to_string());
        parts.push(r.revenue_cents.to_string());
        parts.push(r.spend_cents.to_string());
        parts.push(r.recovered_cents.to_string());
        parts.push(r.payout_cents.to_string());
    }
    for slot in &run.ads {
        parts.push(slot.ad.imps.to_string());
        parts.push(slot.ad.stops.to_string());
        parts.push(slot.ad.clicks.to_string());
        parts.push(slot.ad.buys.to_string());
    }
    let s = parts.join("|");
    crate::rng::fnv1a(&s, 0)
}

/// Reproduce a run from seed + journal: the replay contract.
pub fn replay(cfg: Cfg, journal: &[Command]) -> Run {
    let mut run = new_run(cfg);
    for cmd in journal {
        if run.state == "FLIGHT" {
            if let Some(at) = cmd.at_tick {
                if at > run.tick {
                    let delta = at - run.tick;
                    advance(&mut run, delta);
                }
            }
        }
        command(&mut run, cmd);
    }
    if run.state == "FLIGHT" {
        let delta = run.plan_ticks - run.tick;
        advance(&mut run, delta);
    }
    run
}
