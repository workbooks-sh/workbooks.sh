//! Ground-truth ad funnel. Faithful port of sim/funnel.lua.
//!   impression -> STOP (hook) -> [HOLD, optional] -> CLICK -> CONVERT, AOV on conversion.
//! Conditional structure so displayed metrics keep their real definitions:
//!   P(stop)         = hook_ppm                  (hook rate = stops/imps)
//!   P(hold | stop)  = hold_given_stop_ppm       (OPTIONAL; hold rate = holds/stops)
//!   P(click | ...)  = click_given_stop_ppm      (click|stop when no hold gate, click|HOLD when present)
//!   P(buy  | click) = cvr_ppm                   (CVR = purchases / clicks)
//! HOLD is optional and draw-count-preserving when absent: a truth without
//! hold_given_stop_ppm consumes exactly the rng draws of the pre-hold funnel,
//! so every spike-0a published number stays bit-identical (FINDINGS.md #3).
//! All truth rates are integer ppm; all money is integer cents / millicents
//! (docs/02-technical.md 4: integer-valued sim state; divide at presentation).
use crate::rng::Rng;

/// Layer-1 ground truth for an ad. ppm = integer parts-per-million; money in cents.
#[derive(Clone, Copy)]
pub struct Truth {
    pub hook_ppm: u32,
    pub hold_given_stop_ppm: Option<u32>, // optional gate
    pub click_given_stop_ppm: u32,
    pub cvr_ppm: u32,
    pub aov_cents: u64,
}

/// Live ad state. Integer counters only; division happens at presentation (metrics).
#[derive(Clone)]
pub struct Ad {
    pub truth: Truth,
    pub imps: u64,
    pub stops: u64,
    pub holds: u64,
    pub clicks: u64,
    pub buys: u64,
    pub revenue_cents: u64,
    pub spend_millicents: u64, // per-impression cost in millicents == cpm_cents
}

impl Ad {
    /// Mirrors Funnel.new_ad(truth).
    pub fn new(truth: Truth) -> Ad {
        Ad {
            truth,
            imps: 0,
            stops: 0,
            holds: 0,
            clicks: 0,
            buys: 0,
            revenue_cents: 0,
            spend_millicents: 0,
        }
    }

    /// Mirrors Funnel.sample_impressions(ad, rng, n, per_imp_millicents).
    /// rng draw order is load-bearing for determinism — do not reorder.
    pub fn sample_impressions(&mut self, rng: &mut Rng, n: u64, per_imp_millicents: u64) {
        let t = self.truth;
        for _ in 0..n {
            self.imps += 1;
            self.spend_millicents += per_imp_millicents;
            if rng.bernoulli(t.hook_ppm) {
                self.stops += 1;
                let mut through = true;
                if let Some(hold_ppm) = t.hold_given_stop_ppm {
                    if rng.bernoulli(hold_ppm) {
                        self.holds += 1;
                    } else {
                        through = false;
                    }
                }
                if through && rng.bernoulli(t.click_given_stop_ppm) {
                    self.clicks += 1;
                    if rng.bernoulli(t.cvr_ppm) {
                        self.buys += 1;
                        self.revenue_cents += t.aov_cents;
                    }
                }
            }
        }
    }

    /// Observed metrics — division happens HERE, at presentation, never in state.
    /// Mirrors Funnel.metrics(ad). Floats are presentation-only (Lua uses doubles
    /// here); the deterministic path above is integer-only.
    pub fn metrics(&self) -> Metrics {
        let imps = self.imps;
        let spend_cents = self.spend_millicents as f64 / 1000.0;
        Metrics {
            imps,
            stops: self.stops,
            holds: self.holds,
            clicks: self.clicks,
            buys: self.buys,
            hook_rate: if imps > 0 { self.stops as f64 / imps as f64 } else { 0.0 },
            // hold_rate is Some only when the gate exists AND stops>0 (Lua: 0.0 is
            // truthy, so holds==0 still yields Some(0.0), not None).
            hold_rate: if self.truth.hold_given_stop_ppm.is_some() && self.stops > 0 {
                Some(self.holds as f64 / self.stops as f64)
            } else {
                None
            },
            ctr: if imps > 0 { self.clicks as f64 / imps as f64 } else { 0.0 },
            cvr: if self.clicks > 0 { self.buys as f64 / self.clicks as f64 } else { 0.0 },
            spend_cents,
            revenue_cents: self.revenue_cents,
            roas: if spend_cents > 0.0 { self.revenue_cents as f64 / spend_cents } else { 0.0 },
        }
    }
}

/// Presentation view of an ad (mirrors the table returned by Funnel.metrics).
#[derive(Clone, Copy)]
pub struct Metrics {
    pub imps: u64,
    pub stops: u64,
    pub holds: u64,
    pub clicks: u64,
    pub buys: u64,
    pub hook_rate: f64,
    pub hold_rate: Option<f64>, // None == Lua nil (no gate, or stops==0)
    pub ctr: f64,
    pub cvr: f64,
    pub spend_cents: f64,
    pub revenue_cents: u64,
    pub roas: f64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rng::Rng;

    // Golden values produced by luajit on sim/funnel.lua (full-precision %.17g
    // floats round-trip exactly into f64 literals). See /tmp harness in the port.

    #[test]
    fn scenario_a_no_hold_gate_matches_luajit() {
        let truth = Truth {
            hook_ppm: 300000,
            hold_given_stop_ppm: None,
            click_given_stop_ppm: 200000,
            cvr_ppm: 50000,
            aov_cents: 4999,
        };
        let mut ad = Ad::new(truth);
        let mut rng = Rng::substream(42, "funnel");
        ad.sample_impressions(&mut rng, 10000, 1500);

        assert_eq!((ad.imps, ad.stops, ad.holds, ad.clicks, ad.buys), (10000, 3005, 0, 622, 32));
        assert_eq!(ad.revenue_cents, 159968);
        assert_eq!(ad.spend_millicents, 15000000);

        let m = ad.metrics();
        assert_eq!(m.hook_rate, 0.30049999999999999);
        assert_eq!(m.hold_rate, None);
        assert_eq!(m.ctr, 0.062199999999999998);
        assert_eq!(m.cvr, 0.051446945337620578);
        assert_eq!(m.spend_cents, 15000.0);
        assert_eq!(m.roas, 10.664533333333333);
    }

    #[test]
    fn scenario_b_with_hold_gate_matches_luajit() {
        let truth = Truth {
            hook_ppm: 300000,
            hold_given_stop_ppm: Some(400000),
            click_given_stop_ppm: 250000,
            cvr_ppm: 50000,
            aov_cents: 4999,
        };
        let mut ad = Ad::new(truth);
        let mut rng = Rng::substream(7, "funnel");
        ad.sample_impressions(&mut rng, 10000, 1500);

        assert_eq!((ad.imps, ad.stops, ad.holds, ad.clicks, ad.buys), (10000, 2973, 1204, 295, 13));
        assert_eq!(ad.revenue_cents, 64987);
        assert_eq!(ad.spend_millicents, 15000000);

        let m = ad.metrics();
        assert_eq!(m.hook_rate, 0.29730000000000001);
        assert_eq!(m.hold_rate, Some(0.4049781365623949));
        assert_eq!(m.ctr, 0.029499999999999998);
        assert_eq!(m.cvr, 0.044067796610169491);
        assert_eq!(m.spend_cents, 15000.0);
        assert_eq!(m.roas, 4.3324666666666669);
    }

    #[test]
    fn scenario_c_empty_ad_guards_match_luajit() {
        let truth = Truth {
            hook_ppm: 300000,
            hold_given_stop_ppm: Some(400000),
            click_given_stop_ppm: 250000,
            cvr_ppm: 50000,
            aov_cents: 4999,
        };
        let ad = Ad::new(truth);
        let m = ad.metrics();
        assert_eq!((m.imps, m.stops, m.holds, m.clicks, m.buys), (0, 0, 0, 0, 0));
        // gate present but stops==0 -> Lua nil -> None
        assert_eq!(m.hold_rate, None);
        assert_eq!(m.hook_rate, 0.0);
        assert_eq!(m.ctr, 0.0);
        assert_eq!(m.cvr, 0.0);
        assert_eq!(m.spend_cents, 0.0);
        assert_eq!(m.revenue_cents, 0);
        assert_eq!(m.roas, 0.0);
    }

    #[test]
    fn scenario_d_zero_hold_gate_yields_zero_hold_rate() {
        // gate present (0 ppm): every stop fails hold -> holds==0, stops>0,
        // no click draws happen. Lua 0.0 is truthy => hold_rate = Some(0.0), not None.
        let truth = Truth {
            hook_ppm: 300000,
            hold_given_stop_ppm: Some(0),
            click_given_stop_ppm: 200000,
            cvr_ppm: 50000,
            aov_cents: 4999,
        };
        let mut ad = Ad::new(truth);
        let mut rng = Rng::substream(99, "funnel");
        ad.sample_impressions(&mut rng, 5000, 1500);

        assert_eq!((ad.imps, ad.stops, ad.holds, ad.clicks, ad.buys), (5000, 1539, 0, 0, 0));
        assert_eq!(ad.revenue_cents, 0);
        assert_eq!(ad.spend_millicents, 7500000);

        let m = ad.metrics();
        assert_eq!(m.hold_rate, Some(0.0));
        assert_eq!(m.hook_rate, 0.30780000000000002);
        assert_eq!(m.ctr, 0.0);
        assert_eq!(m.cvr, 0.0);
        assert_eq!(m.spend_cents, 7500.0);
        assert_eq!(m.roas, 0.0);
    }
}
