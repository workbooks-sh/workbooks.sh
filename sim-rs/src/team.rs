//! Team cards — the joker row (docs/design/team-cards.md). Port of sim/team.lua.
//!
//! Run-scoped hires in desk slots (pillar 3: the hireable POOL broadens across
//! runs; hires never persist). Per-wave salaries make team size fight the
//! interest mechanic — the agency P&L lesson — and firing is a verb with
//! severance. THE BANNED-LEVER LAW, enforced at hire time: effects flow only
//! through real machinery (capacity, information, costs, aspect alignment,
//! fatigue, quality tradeoffs); revenue/ROAS multipliers and anything touching
//! significance are rejected — team quality flows through creative quality, and
//! n is n. Traits (calibration bias, style) ride along as data for the
//! hypothesis engine (sim/strategist.lua).
//!
//! Deterministic, no RNG, integer money (cents). All integers are i64.

/// The whitelist IS the law: only these effect fields exist. Kept as data for
/// fidelity with the Lua `LEGAL_EFFECTS` table; content loaders route any
/// non-whitelisted key into `Effects::illegal` so `hire` can reject it.
pub const LEGAL_EFFECTS: [&str; 6] = [
    "capacity",            // +ads per build (wave machine consumes)
    "hook_quality_x1000",  // quality tradeoff on this hire's output (<=1000)
    "aspect_bonus",        // { aspect, pts } -> resonance-side bonus
    "fatigue_rate_x1000",  // wear management (<=1000 slows, never reverses)
    "ip_discount",         // cheaper V2 mints (economy consumes)
    "info_lines",          // dossier lines revealed early (information)
];

/// True for any effect key on the banned-lever whitelist.
pub fn is_legal_effect(key: &str) -> bool {
    LEGAL_EFFECTS.contains(&key)
}

/// Resonance-side bonus carried by a hire ({ aspect, pts } in the Lua).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AspectBonus {
    pub aspect: String,
    pub pts: i64,
}

/// A hire's effect bundle. Each legal lever is an `Option` (absent == not set,
/// mirroring a missing Lua table key). `illegal` carries any non-whitelisted
/// keys the content author tried to use — its presence is what `effects_legal`
/// rejects (THE BANNED-LEVER LAW). Aggregation order over a desk is fixed
/// (slot order), so this stays deterministic with no `pairs()`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Effects {
    pub capacity: Option<i64>,
    pub hook_quality_x1000: Option<i64>,
    pub aspect_bonus: Option<AspectBonus>,
    pub fatigue_rate_x1000: Option<i64>,
    pub ip_discount: Option<i64>,
    pub info_lines: Option<i64>,
    /// Non-whitelisted effect keys present on the source content (e.g.
    /// `roas_x1000`, `significance_z_discount`). Any entry here makes the hire
    /// illegal.
    pub illegal: Vec<String>,
}

/// Traits ride along as data for the hypothesis engine (sim/strategist.lua).
/// They never feed team machinery; team just preserves them on the hire.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Traits {
    pub confidence_bias_x1000: i64,
    pub style: String,
    pub skill_x1000: i64,
}

/// A hireable card. `effects` flows through real machinery; `traits` is data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HireDef {
    pub id: String,
    pub role: String,
    pub salary_cents: i64,
    pub traits: Traits,
    pub effects: Effects,
}

/// A desk with a fixed slot count and the hires currently seated in it.
#[derive(Clone, Debug, Default)]
pub struct Desk {
    pub slots: usize,
    pub hires: Vec<HireDef>,
}

/// Aggregate desk effects consumed by the other systems. Identity values match
/// the Lua: additive levers start at 0, multiplicative rates start at 1000.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeskEffects {
    pub capacity: i64,
    pub ip_discount: i64,
    pub info_lines: i64,
    pub hook_quality_x1000: i64,
    pub fatigue_rate_x1000: i64,
    pub aspect_bonuses: Vec<AspectBonus>,
}

pub fn new_desk(slots: usize) -> Desk {
    Desk { slots, hires: Vec::new() }
}

/// Hire-time validation: tool boundary, not tick path. A hire is legal iff it
/// carries no non-whitelisted effect keys.
fn effects_legal(effects: &Effects) -> bool {
    effects.illegal.is_empty()
}

/// Seat a hire. Rejects (returns false) if the desk is full, the effects break
/// the banned-lever law, or an identical id is already on the desk. Mirrors the
/// Lua, which stores the hiredef; here we clone it into the slot.
pub fn hire(desk: &mut Desk, hiredef: &HireDef) -> bool {
    if desk.hires.len() >= desk.slots {
        return false;
    }
    if !effects_legal(&hiredef.effects) {
        return false;
    }
    for h in &desk.hires {
        if h.id == hiredef.id {
            return false;
        }
    }
    desk.hires.push(hiredef.clone());
    true
}

/// Severance = one salary. `bank_cents` mirrors the Lua `bank.cents` (mutated in
/// place). Returns false if the id is not on the desk or the bankroll can't
/// cover severance — and in the can't-pay case the hire stays seated.
pub fn fire(desk: &mut Desk, id: &str, bank_cents: &mut i64) -> bool {
    if let Some(i) = desk.hires.iter().position(|h| h.id == id) {
        let salary = desk.hires[i].salary_cents;
        if *bank_cents < salary {
            return false;
        }
        *bank_cents -= salary;
        desk.hires.remove(i);
        return true;
    }
    false
}

pub fn payroll_cents(desk: &Desk) -> i64 {
    desk.hires.iter().map(|h| h.salary_cents).sum()
}

/// Paid at every wave Close, BEFORE interest accrues — that ordering is the
/// lesson: headcount eats the compounding engine first. `bank_cents` mirrors
/// `bank.cents`.
pub fn pay_wave(desk: &Desk, bank_cents: &mut i64) -> bool {
    let due = payroll_cents(desk);
    if *bank_cents < due {
        return false;
    }
    *bank_cents -= due;
    true
}

/// Aggregate desk effects for the other systems. Multiplicative rates compound
/// in slot order with integer (floor, non-negative inputs) division, matching
/// the Lua `math.floor(acc * e / 1000)`.
pub fn effects(desk: &Desk) -> DeskEffects {
    let mut fx = DeskEffects {
        capacity: 0,
        ip_discount: 0,
        info_lines: 0,
        hook_quality_x1000: 1000,
        fatigue_rate_x1000: 1000,
        aspect_bonuses: Vec::new(),
    };
    for h in &desk.hires {
        let e = &h.effects;
        fx.capacity += e.capacity.unwrap_or(0);
        fx.ip_discount += e.ip_discount.unwrap_or(0);
        fx.info_lines += e.info_lines.unwrap_or(0);
        if let Some(q) = e.hook_quality_x1000 {
            fx.hook_quality_x1000 = fx.hook_quality_x1000 * q / 1000;
        }
        if let Some(f) = e.fatigue_rate_x1000 {
            fx.fatigue_rate_x1000 = fx.fatigue_rate_x1000 * f / 1000;
        }
        if let Some(ab) = &e.aspect_bonus {
            fx.aspect_bonuses.push(ab.clone());
        }
    }
    fx
}

pub fn max_builds(base: i64, desk: &Desk) -> i64 {
    base + effects(desk).capacity
}

#[cfg(test)]
mod tests {
    use super::*;

    // Test fixtures mirror test/sim/test_team.lua.
    fn strategist() -> HireDef {
        HireDef {
            id: "maya_strategist".into(),
            role: "creative_strategist".into(),
            salary_cents: 4000,
            traits: Traits { confidence_bias_x1000: 1300, style: "creative".into(), skill_x1000: 650 },
            effects: Effects {
                aspect_bonus: Some(AspectBonus { aspect: "social_proof".into(), pts: 1 }),
                info_lines: Some(1),
                ..Default::default()
            },
        }
    }
    fn offshore() -> HireDef {
        HireDef {
            id: "vantage_offshore".into(),
            role: "offshore_agency".into(),
            salary_cents: 2500,
            traits: Traits { confidence_bias_x1000: 1000, style: "analytical".into(), skill_x1000: 450 },
            effects: Effects { capacity: Some(2), hook_quality_x1000: Some(950), ..Default::default() },
        }
    }
    fn editor() -> HireDef {
        HireDef {
            id: "sam_editor".into(),
            role: "senior_editor".into(),
            salary_cents: 3000,
            traits: Traits { confidence_bias_x1000: 900, style: "analytical".into(), skill_x1000: 700 },
            effects: Effects { ip_discount: Some(2), fatigue_rate_x1000: Some(900), ..Default::default() },
        }
    }
    fn simple(id: &str, salary: i64, e: Effects) -> HireDef {
        HireDef { id: id.into(), role: "x".into(), salary_cents: salary, traits: Traits::default(), effects: e }
    }

    // ---- Goldens below are byte-for-byte from luajit on sim/team.lua. ----

    #[test]
    fn desk_slots_cap_hires() {
        let mut desk = new_desk(2);
        assert!(hire(&mut desk, &strategist())); // hire1 true
        assert!(hire(&mut desk, &offshore())); // hire2 true
        assert!(!hire(&mut desk, &editor())); // hire3_full false
        assert!(!hire(&mut desk, &strategist())); // hire_dup false (also already full)
        assert_eq!(desk.hires.len(), 2); // ndesk 2
    }

    #[test]
    fn duplicate_id_rejected_when_room() {
        let mut desk = new_desk(3);
        assert!(hire(&mut desk, &strategist()));
        assert!(!hire(&mut desk, &strategist())); // same id rejected even with a free slot
        assert_eq!(desk.hires.len(), 1);
    }

    #[test]
    fn banned_lever_law_rejects_illegal_effects() {
        // roas multiplier — content author tried a banned lever.
        let cheat = simple("cheater", 1000, Effects { illegal: vec!["roas_x1000".into()], ..Default::default() });
        assert!(!hire(&mut new_desk(3), &cheat)); // cheat_roas false
        // anything touching significance.
        let cheat2 = simple("p", 1000, Effects { illegal: vec!["significance_z_discount".into()], ..Default::default() });
        assert!(!hire(&mut new_desk(3), &cheat2)); // cheat_sig false
        assert!(!is_legal_effect("roas_x1000"));
        assert!(is_legal_effect("capacity"));
    }

    #[test]
    fn payroll_fire_and_pay_wave_money_flow() {
        let mut desk = new_desk(2);
        hire(&mut desk, &strategist());
        hire(&mut desk, &offshore());
        assert_eq!(payroll_cents(&desk), 6500); // payroll 6500
        let mut bank = 10000i64;
        assert!(pay_wave(&desk, &mut bank)); // pay_wave true
        assert_eq!(bank, 3500); // bank 3500
        assert!(fire(&mut desk, "vantage_offshore", &mut bank)); // fire_off true
        assert_eq!(bank, 1000); // bank 1000
        assert_eq!(desk.hires.len(), 1); // n 1
        assert!(!fire(&mut desk, "nobody", &mut bank)); // fire_stranger false
    }

    #[test]
    fn pay_wave_insufficient_funds() {
        let mut poor = 100i64;
        assert!(pay_wave(&new_desk(2), &mut poor)); // empty desk due=0 -> true
        let mut d_one = new_desk(1);
        hire(&mut d_one, &editor());
        assert!(!pay_wave(&d_one, &mut poor)); // due 3000 > 100 -> false
        assert_eq!(poor, 100); // bank untouched
    }

    #[test]
    fn fire_without_severance_keeps_hire() {
        let mut d_fire = new_desk(1);
        hire(&mut d_fire, &strategist());
        let mut bank = 10i64;
        assert!(!fire(&mut d_fire, "maya_strategist", &mut bank)); // fire_nopay false
        assert_eq!(bank, 10); // bank 10
        assert_eq!(d_fire.hires.len(), 1); // n 1 — hire stays seated
    }

    #[test]
    fn effects_aggregate_across_desk() {
        let mut d2 = new_desk(3);
        hire(&mut d2, &strategist());
        hire(&mut d2, &offshore());
        hire(&mut d2, &editor());
        let fx = effects(&d2);
        assert_eq!(fx.capacity, 2);
        assert_eq!(fx.ip_discount, 2);
        assert_eq!(fx.info_lines, 1);
        assert_eq!(fx.hook_quality_x1000, 950);
        assert_eq!(fx.fatigue_rate_x1000, 900);
        assert_eq!(fx.aspect_bonuses.len(), 1);
        assert_eq!(fx.aspect_bonuses[0], AspectBonus { aspect: "social_proof".into(), pts: 1 });
    }

    #[test]
    fn empty_desk_effects_are_identity() {
        let fe = effects(&new_desk(2));
        assert_eq!(fe.hook_quality_x1000, 1000);
        assert_eq!(fe.fatigue_rate_x1000, 1000);
        assert_eq!(fe.capacity, 0);
        assert_eq!(fe.aspect_bonuses.len(), 0);
    }

    #[test]
    fn multiplicative_rates_floor_in_slot_order() {
        let mut dq = new_desk(2);
        hire(&mut dq, &simple("q1", 1, Effects { hook_quality_x1000: Some(950), ..Default::default() }));
        hire(&mut dq, &simple("q2", 1, Effects { hook_quality_x1000: Some(950), ..Default::default() }));
        // floor(1000*950/1000)=950 then floor(950*950/1000)=902
        assert_eq!(effects(&dq).hook_quality_x1000, 902);

        let mut df = new_desk(2);
        hire(&mut df, &simple("f1", 1, Effects { fatigue_rate_x1000: Some(900), ..Default::default() }));
        hire(&mut df, &simple("f2", 1, Effects { fatigue_rate_x1000: Some(333), ..Default::default() }));
        // floor(900) then floor(900*333/1000)=299
        assert_eq!(effects(&df).fatigue_rate_x1000, 299);
    }

    #[test]
    fn max_builds_is_pure_over_the_desk() {
        let mut d2 = new_desk(3);
        hire(&mut d2, &strategist());
        hire(&mut d2, &offshore());
        hire(&mut d2, &editor());
        assert_eq!(max_builds(2, &d2), 4); // base 2 + offshore capacity 2
        assert_eq!(max_builds(2, &new_desk(2)), 2); // bare desk = base capacity
    }

    #[test]
    fn traits_ride_along_for_the_hypothesis_engine() {
        let mut desk = new_desk(2);
        hire(&mut desk, &strategist());
        hire(&mut desk, &offshore());
        assert_eq!(desk.hires[0].traits.style, "creative");
        assert_eq!(desk.hires[0].traits.confidence_bias_x1000, 1300);
    }
}
