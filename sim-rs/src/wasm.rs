//! JS-facing WASM bridge (wasm-bindgen). Returns JSON strings to avoid a serde
//! dep — the UI parses. Two surfaces:
//!   1. BRAND exports (the spinner/identity screen): random_brand, colors_json,
//!      glyphs_for, roll_name — name from substream(seed,"ident"), recipe from
//!      substream(seed,"logo").
//!   2. DASHBOARD — a stateful `Dashboard` handle the HTML game loop drives turn
//!      by turn. It owns a `game::Game` and mirrors sim/wave.lua + sim/game.lua:
//!      ack_brief -> build_ad (launch) -> end_day (go + advance one day, settle on
//!      autopsy) -> next_wave (leave the newsstand). All getters return JSON;
//!      determinism is untouched (the funnel rng path is identical to the proven
//!      `game::play_wave`; the only added gate is per-day attention, which only
//!      decides whether a launch is accepted, never the draws after it).
//!   3. WRI `call(name, argsJson) -> String` — see wasm_call.rs.
use wasm_bindgen::prelude::*;
use crate::rng::Rng;
use crate::namegen;
use crate::logo;
use crate::logo_data::COLORS;
use crate::{game, wave, diagnosis, fatigue, ledger};
use serde_json;

fn esc(s: &str) -> String { s.replace('\\', "\\\\").replace('"', "\\\"") }

// ============================================================ brand exports

/// One themed brand for (seed, vertical): name + logo recipe, as JSON.
#[wasm_bindgen]
pub fn random_brand(seed: u32, vertical: &str) -> String {
    let mut ir = Rng::substream(seed, "ident");
    let id = namegen::identity(&mut ir, vertical);
    let mut lr = Rng::substream(seed, "logo");
    let rec = logo::random(&mut lr, vertical);
    let traits = id.traits.iter().map(|t| format!("\"{}\"", esc(t))).collect::<Vec<_>>().join(",");
    format!(
        "{{\"name\":\"{}\",\"vertical\":\"{}\",\"traits\":[{}],\"glyph\":\"{}\",\"font\":\"{}\",\"layout\":\"{}\",\"c1\":{},\"c2\":{},\"c3\":{}}}",
        esc(&id.name), esc(vertical), traits, esc(&rec.glyph), esc(&rec.font), esc(&rec.layout), rec.c1, rec.c2, rec.c3
    )
}

/// The full color pool as a JSON array of [r,g,b] (the spinner reel).
#[wasm_bindgen]
pub fn colors_json() -> String {
    let mut s = String::from("[");
    for (i, c) in COLORS.iter().enumerate() {
        if i > 0 { s.push(','); }
        s.push_str(&format!("[{},{},{}]", c[0], c[1], c[2]));
    }
    s.push(']');
    s
}

/// Suggested glyph ids for a vertical, JSON array.
#[wasm_bindgen]
pub fn glyphs_for(vertical: &str) -> String {
    let g = logo::glyphs_for(vertical);
    format!("[{}]", g.iter().map(|x| format!("\"{}\"", x)).collect::<Vec<_>>().join(","))
}

/// Roll just a fresh name for the current vertical (the "Roll a name" button).
#[wasm_bindgen]
pub fn roll_name(seed: u32, vertical: &str) -> String {
    let mut r = Rng::substream(seed, "ident");
    esc(&namegen::brand(&mut r, vertical, &[]))
}

// ============================================================ dashboard

/// Attention points the HTML loop grants per game-day. A launch costs 1 AP
/// (sim/wave.lua AP_COST); kill stays free. Refills each morning during flight.
const DASH_AP_PER_DAY: i64 = 3;

/// JSON-encode a flight event stream (mirrors the Lua event tables).
fn events_json(events: &[wave::Event]) -> String {
    let mut s = String::from("[");
    for (i, e) in events.iter().enumerate() {
        if i > 0 { s.push(','); }
        match e {
            wave::Event::Killed { ad, tick } =>
                s.push_str(&format!("{{\"type\":\"killed\",\"ad\":{},\"tick\":{}}}", ad, tick)),
            wave::Event::DayEnd { day } =>
                s.push_str(&format!("{{\"type\":\"day_end\",\"day\":{}}}", day)),
            wave::Event::Bell { winner, verdict, day } =>
                s.push_str(&format!("{{\"type\":\"bell\",\"winner\":{},\"verdict\":\"{}\",\"day\":{}}}", winner, esc(verdict), day)),
            wave::Event::Autopsy { passed, state } =>
                s.push_str(&format!("{{\"type\":\"autopsy\",\"passed\":{},\"state\":\"{}\"}}", passed, esc(state))),
        }
    }
    s.push(']');
    s
}

/// Stateful game handle the HTML loop drives. Owns the full engagement plus the
/// per-wave specs/pins the settlement needs (carried across build_ad calls).
#[wasm_bindgen]
pub struct Dashboard {
    seed: u32,
    g: game::Game,
    specs: Vec<game::Spec>,
    pins: Vec<game::PinSpec>,
    codex: ledger::Codex,
    call_idx: usize,
}

#[wasm_bindgen]
impl Dashboard {
    /// Build a handle and start a run on `seed` (lands in BUILD, brief acked).
    #[wasm_bindgen(constructor)]
    pub fn new(seed: u32) -> Dashboard {
        let mut d = Dashboard {
            seed,
            g: game::new(seed, game::demo_pack()),
            specs: Vec::new(),
            pins: Vec::new(),
            codex: ledger::new_codex(),
            call_idx: 0,
        };
        d.reset(seed);
        d
    }

    fn reset(&mut self, seed: u32) {
        self.seed = seed;
        self.g = game::new(seed, game::demo_pack());
        // Give the loop a real attention budget (a deterministic launch gate;
        // the funnel rng path after a launch is identical to the proven game).
        self.g.run.cfg.ap_per_day = Some(DASH_AP_PER_DAY);
        self.g.run.ap = Some(DASH_AP_PER_DAY);
        self.specs.clear();
        self.pins.clear();
        self.call_idx = 0;
        wave::command(&mut self.g.run, &wave::Command::new("ack_brief")); // -> BUILD
    }

    /// (Re)start a run on `seed`; returns the initial state JSON.
    pub fn start_run(&mut self, seed: u32) -> String {
        self.reset(seed);
        self.state_json()
    }

    /// Current state snapshot as JSON (day, AP, bankroll, revenue, target,
    /// ads[], race, trust, plus client/brief context and last_result).
    pub fn get_state(&self) -> String {
        self.state_json()
    }

    /// Compose `card_ids` (comma-separated, on the current lane) into a truth and
    /// launch it. Legal in BUILD (queues a build) or mid-FLIGHT (joins the week).
    /// `clean` flags a clean A/B test. Returns {ok, msg?, state}.
    pub fn build_ad(&mut self, card_ids: &str, clean: bool) -> String {
        let st = self.g.run.state.clone();
        if st != "BUILD" && st != "FLIGHT" {
            return format!("{{\"ok\":false,\"msg\":\"cannot build in {}\",\"state\":{}}}", esc(&st), self.state_json());
        }
        let ids: Vec<String> = card_ids
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if ids.is_empty() {
            return format!("{{\"ok\":false,\"msg\":\"no cards\",\"state\":{}}}", self.state_json());
        }
        for id in &ids {
            if !self.g.cards.contains_key(id) {
                return format!("{{\"ok\":false,\"msg\":\"unknown card {}\",\"state\":{}}}", esc(id), self.state_json());
            }
        }
        let pick = game::Pick { card_ids: ids, clean: Some(clean) };
        let (ok, spec) = game::compose_and_launch(&mut self.g, &pick);
        if ok {
            self.specs.push(spec);
        }
        format!("{{\"ok\":{},\"state\":{}}}", ok, self.state_json())
    }

    /// Queue a free KILL on ad `idx` (1-based); consumed at the next tick
    /// boundary, recovering the unspent budget. Legal only in FLIGHT.
    pub fn kill_ad(&mut self, idx: usize) -> String {
        let ok = if self.g.run.state == "FLIGHT" {
            wave::command(
                &mut self.g.run,
                &wave::Command { kind: "kill".into(), ad: Some(idx), ..Default::default() },
            )
        } else {
            false
        };
        format!("{{\"ok\":{},\"state\":{}}}", ok, self.state_json())
    }

    /// Advance the turn one game-day. In BUILD this first starts the flight
    /// (needs builds totalling the spend floor). When the flight ends, the wave
    /// is settled at the game level (wear/combos/shimmer/ledger/economy) and the
    /// run parks at the NEWSSTAND — call `next_wave` to continue. Returns
    /// {ok, events, state}.
    pub fn end_day(&mut self) -> String {
        if self.g.run.state == "BUILD" {
            if !game::begin_flight(&mut self.g) {
                return format!(
                    "{{\"ok\":false,\"msg\":\"need ads totalling the spend floor to fly\",\"events\":[],\"state\":{}}}",
                    self.state_json()
                );
            }
        }
        let events = wave::end_day(&mut self.g.run);
        if events.iter().any(|e| matches!(e, wave::Event::Autopsy { .. })) {
            let specs = std::mem::take(&mut self.specs);
            let pins = std::mem::take(&mut self.pins);
            game::settle_wave(&mut self.g, &specs, &pins, true);
            let run_id = self.g.run.global_wave.to_string();
            for note in &self.g.ledger.notes {
                ledger::codex_observe(&mut self.codex, &run_id, &ledger::Claim {
                    aspect: note.aspect.clone(), stage: note.stage.clone(),
                    metric: note.metric.clone(), direction: note.direction,
                });
            }
        }
        format!("{{\"ok\":true,\"events\":{},\"state\":{}}}", events_json(&events), self.state_json())
    }

    /// Register an A/B PIN prediction before or during the flight.
    /// `metric` = "HOOK"/"CTR"/"CVR"; `call` = 1 (predict A wins) or 2 (B wins).
    /// Graded at autopsy; verdict lands in last_result.pins[0] via the significance engine.
    pub fn pin_ab(&mut self, metric: &str, call: usize) -> String {
        let ok = wave::command(&mut self.g.run, &wave::Command {
            kind: "pin".into(),
            a: Some(1), b: Some(2),
            metric: Some(metric.to_string()),
            call: Some(call),
            ..Default::default()
        });
        if ok {
            // Derive claim aspect from the predicted winner's hook card (highest-pts aspect).
            let pred_idx = call.saturating_sub(1);
            let aspect = self.specs.get(pred_idx)
                .and_then(|s| s.cards.iter().filter_map(|c| self.g.cards.get(&c.id))
                    .find(|c| c.kind == "hook"))
                .and_then(|c| c.aspects.iter().max_by_key(|a| a.pts))
                .map(|a| a.name.clone())
                .unwrap_or_else(|| "unknown".to_string());
            self.pins.push(game::PinSpec {
                a: 1, b: 2, metric: metric.to_string(), call,
                claim: Some(game::Claim { aspect, direction: if call == 1 { 1 } else { -1 } }),
            });
        }
        format!("{{\"ok\":{}}}", ok)
    }

    /// Declare ad `idx` (1-based) as the predicted winner. Records once per wave;
    /// verdict (CONFIRMED/INCORRECT) is derived from final revenues at autopsy.
    pub fn call_it(&mut self, idx: usize) -> String {
        if self.call_idx != 0 || self.g.run.state != "FLIGHT" { return "{\"ok\":false}".into(); }
        self.call_idx = idx;
        "{\"ok\":true}".into()
    }

    /// Run the 6-case diagnosis engine on ad `idx` (1-based). Legal only in
    /// FLIGHT once the ad has enough imps (≥2000). Returns:
    ///   {diagnosable: true, case, chip, sentence}  — a diagnosis verdict
    ///   {diagnosable: false}                        — below floor or wrong state
    pub fn diagnose_ad(&self, idx: usize) -> String {
        if self.g.run.state != "FLIGHT" { return "{\"diagnosable\":false}".into(); }
        if idx < 1 || idx > self.g.run.ad_count() { return "{\"diagnosable\":false}".into(); }
        let ad = self.g.run.ad_counts(idx);
        let obs = diagnosis::Obs {
            imps: ad.imps as i64, stops: ad.stops as i64,
            holds: ad.holds as i64, clicks: ad.clicks as i64,
            buys: ad.buys as i64, ..Default::default()
        };
        match diagnosis::diagnose(&obs) {
            Some(v) => format!("{{\"diagnosable\":true,\"case\":\"{}\",\"chip\":\"{}\",\"sentence\":{}}}",
                esc(v.case), esc(v.chip), serde_json::to_string(&v.sentence).unwrap_or("\"\"".into())),
            None => "{\"diagnosable\":false}".into(),
        }
    }

    /// Leave the newsstand for the next brief (the Lua skip_shop handshake), then
    /// ack the new brief into BUILD. No-op unless parked at the NEWSSTAND.
    pub fn next_wave(&mut self) -> String {
        if self.g.run.state == "NEWSSTAND" {
            wave::command(&mut self.g.run, &wave::Command::new("skip_shop"));
            if self.g.run.state == "BRIEF" {
                wave::command(&mut self.g.run, &wave::Command::new("ack_brief"));
            }
        }
        self.state_json()
    }

    // ---------------------------------------------------------- internals

    fn state_json(&self) -> String {
        let g = &self.g;
        let run = &g.run;
        let state = run.state.clone();

        // brief context — guarded (RUN_WON walks client_i past the roster).
        let have_brief = run.client_i >= 1 && run.client_i <= g.pack.clients.len();
        let (client_id, wic, is_boss, target, spend_floor, fee) = if have_brief {
            let b = wave::brief(run);
            (b.client, b.wave_in_client, b.is_boss, b.target_cents, b.spend_floor_cents, b.fee_cents)
        } else {
            (String::new(), 0usize, false, 0i64, 0i64, 0i64)
        };

        // ads carry live flight data only once a flight has data; BUILD/BRIEF
        // preview the queued builds via `builds` instead (run.ads is stale then).
        let show_ads = matches!(state.as_str(), "FLIGHT" | "NEWSSTAND" | "FIRED" | "RUN_WON");
        let mut ads = String::from("[");
        let mut live_rev: i64 = 0;
        if show_ads {
            for i in 1..=run.ad_count() {
                let ad = run.ad_counts(i);
                let killed = run.ad_killed(i);
                let (imps, stops, clicks, buys) = (ad.imps, ad.stops, ad.clicks, ad.buys);
                let rev = ad.revenue_cents as i64;
                let spend = (ad.spend_millicents / 1000) as i64;
                live_rev += rev;
                let hook_ppm = if imps > 0 { stops * 1_000_000 / imps } else { 0 };
                let ctr_ppm = if imps > 0 { clicks * 1_000_000 / imps } else { 0 };
                let cvr_ppm = if clicks > 0 { buys * 1_000_000 / clicks } else { 0 };
                let roas_x1000 = if spend > 0 { rev * 1000 / spend } else { 0 };
                if i > 1 { ads.push(','); }
                ads.push_str(&format!(
                    "{{\"idx\":{},\"killed\":{},\"imps\":{},\"stops\":{},\"clicks\":{},\"buys\":{},\"rev\":{},\"spend\":{},\"hook_ppm\":{},\"ctr_ppm\":{},\"cvr_ppm\":{},\"roas_x1000\":{}}}",
                    i, killed, imps, stops, clicks, buys, rev, spend, hook_ppm, ctr_ppm, cvr_ppm, roas_x1000
                ));
            }
        }
        ads.push(']');

        // queued-build preview (projected funnel truth before flight).
        let lane_id = self.g.pack.clients[self.g.run.client_i - 1].lane.clone().unwrap_or_default();
        let mut builds = String::from("[");
        for (j, s) in self.specs.iter().enumerate() {
            if j > 0 { builds.push(','); }
            let cids = s.card_ids.iter().map(|c| format!("\"{}\"", esc(c))).collect::<Vec<_>>().join(",");
            let wear_map = self.g.wear.get(&lane_id);
            let fatigue = s.card_ids.iter().map(|c| wear_map.and_then(|m| m.get(c)).map(fatigue::status).unwrap_or("FRESH")).fold("FRESH", |acc, st| {
                if st == "CREATIVE FATIGUE" || acc == "CREATIVE FATIGUE" { "CREATIVE FATIGUE" }
                else if st == "CREATIVE LIMITED" || acc == "CREATIVE LIMITED" { "CREATIVE LIMITED" }
                else { "FRESH" }
            });
            builds.push_str(&format!(
                "{{\"cards\":[{}],\"hook_ppm\":{},\"click_ppm\":{},\"cvr_ppm\":{},\"fatigue\":\"{}\"}}",
                cids, s.truth.hook_ppm, s.truth.click_given_stop_ppm, s.truth.cvr_ppm, fatigue
            ));
        }
        builds.push(']');

        let revenue = if state == "FLIGHT" {
            live_rev
        } else if let Some(r) = &run.last_result {
            r.revenue_cents
        } else {
            live_rev
        };
        let race_ppm = if target > 0 {
            (revenue.max(0) as i128 * 1_000_000 / target as i128) as i64
        } else {
            0
        };
        let day = if run.ticks_per_day > 0 { run.tick / run.ticks_per_day } else { 0 };
        let total_days = run.cfg.flight_cfg.days;
        let ap = match run.ap { Some(a) => a.to_string(), None => "null".to_string() };
        let ap_per_day = match run.cfg.ap_per_day { Some(a) => a.to_string(), None => "null".to_string() };

        let last_result = match &run.last_result {
            Some(r) => {
                let p0 = r.pins.first();
                let pverdict = p0.and_then(|p| p.verdict.as_deref()).unwrap_or("NONE");
                let pmetric  = p0.map(|p| p.metric.as_str()).unwrap_or("");
                let pcall    = p0.map(|p| p.call).unwrap_or(0);
                format!(
                    "{{\"passed\":{},\"revenue_cents\":{},\"spend_cents\":{},\"recovered_cents\":{},\"payout_cents\":{},\"is_boss\":{},\"pin_verdict\":\"{}\",\"pin_metric\":\"{}\",\"pin_call\":{}}}",
                    r.passed, r.revenue_cents, r.spend_cents, r.recovered_cents, r.payout_cents, r.is_boss,
                    esc(pverdict), esc(pmetric), pcall
                )
            },
            None => "null".to_string(),
        };

        let cp = ledger::codex_progress(&self.codex);
        let winner_idx = (1..=run.ad_count()).max_by_key(|&i| run.ad_counts(i).revenue_cents).unwrap_or(1);
        let call_verdict = if self.call_idx == 0 { "NONE" } else if self.call_idx == winner_idx { "CONFIRMED" } else { "INCORRECT" };
        let last_pack_json = format!("[{}]", g.stats.last_pack.iter().map(|s| format!("\"{}\"", esc(s))).collect::<Vec<_>>().join(","));
        format!(
            "{{\"seed\":{},\"state\":\"{}\",\"day\":{},\"total_days\":{},\"ap\":{},\"ap_per_day\":{},\"bankroll\":{},\"target\":{},\"revenue\":{},\"race_ppm\":{},\"trust\":{},\"spend_floor\":{},\"fee\":{},\"client\":\"{}\",\"wave_in_client\":{},\"global_wave\":{},\"is_boss\":{},\"builds\":{},\"ads\":{},\"last_result\":{},\"codex\":{{\"canon\":{},\"observed\":{}}},\"call_idx\":{},\"call_verdict\":\"{}\",\"packs_opened\":{},\"last_pack\":{},\"collection_size\":{}}}",
            self.seed, esc(&state), day, total_days, ap, ap_per_day, g.bank.cents, target, revenue,
            race_ppm, run.pips, spend_floor, fee, esc(&client_id), wic, run.global_wave, is_boss,
            builds, ads, last_result, cp.canon, cp.observed, self.call_idx, esc(call_verdict),
            g.stats.packs_opened, last_pack_json, g.collection.owned.len()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A full wave through the dashboard turn machine must end at the SAME bank/
    // state as the proven game::play_wave on the same seed+picks (the bridge is
    // just a finer-grained driver of the identical sim path).
    #[test]
    fn dashboard_wave_matches_play_wave() {
        let cards = "hook_pain,vis_ugc,fmt_video";

        // reference: one wave via game::play_wave (no AP gate, buy_pack=false).
        let mut gref = game::new(123, game::demo_pack());
        let picks = vec![
            game::Pick { card_ids: cards.split(',').map(|s| s.to_string()).collect(), clean: Some(false) },
            game::Pick { card_ids: cards.split(',').map(|s| s.to_string()).collect(), clean: Some(false) },
        ];
        let (res_ref, _revs) = game::play_wave(&mut gref, &picks, &[], false);

        // dashboard: same wave, driven day by day.
        let mut d = Dashboard::new(123);
        d.build_ad(cards, false);
        d.build_ad(cards, false);
        let mut saw_autopsy = false;
        for _ in 0..10 {
            let out = d.end_day();
            if out.contains("\"type\":\"autopsy\"") {
                saw_autopsy = true;
                break;
            }
        }
        assert!(saw_autopsy, "flight should reach autopsy within the week");

        // identical funnel outcome (AP gates only acceptance, not the draws).
        let r = &d.g.run.last_result.as_ref().unwrap();
        assert_eq!(r.revenue_cents, res_ref.revenue_cents);
        assert_eq!(r.passed, res_ref.passed);
        assert_eq!(r.payout_cents, res_ref.payout_cents);
    }

    // The handle is reproducible: same seed + same inputs -> identical state JSON.
    #[test]
    fn dashboard_is_deterministic() {
        let run_once = || {
            let mut d = Dashboard::new(7);
            d.build_ad("hook_fomo,vis_demo,fmt_carousel", true);
            d.build_ad("hook_stat,vis_before,fmt_video", true);
            for _ in 0..10 {
                if d.end_day().contains("\"type\":\"autopsy\"") {
                    break;
                }
            }
            d.get_state()
        };
        assert_eq!(run_once(), run_once());
    }

    #[test]
    fn start_run_lands_in_build() {
        let mut d = Dashboard::new(1);
        let s = d.start_run(99);
        assert!(s.contains("\"state\":\"BUILD\""));
        assert!(s.contains("\"seed\":99"));
        assert!(s.contains("\"ap\":3"));
    }

}
