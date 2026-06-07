//! Composition rules. Pure port of sim/composer.lua — deterministic, no RNG,
//! integer math (every Lua `math.floor(a*b/1000)` is i64 truncating division;
//! all operands are non-negative so floor == truncation here).
//!
//! THE CAPACITY BUDGET: cards carry weight; ads have capacity; composing over
//! budget is allowed — with a monotone, floored LEGIBILITY penalty on hook and
//! hold only. Click intent and cvr are untouched: clutter loses attention,
//! not the lander.
//!
//! COMBINATION FATIGUE: the Andromeda echo penalty. Wear keyed on the composed
//! SET (order-free): reusing the same combination accelerates the ad's fatigue
//! accrual; swapping even one card is a new combination at baseline. Composes
//! multiplicatively with the resonance fatigue rate into Fatigue.expose.

use std::collections::BTreeMap;

pub const PENALTY_FLOOR_X1000: i64 = 600;
pub const COMBO_RATE_CAP_X1000: i64 = 2000;
const PENALTY_PER_OVER_X1000: i64 = 120;
const COMBO_RATE_PER_USE_X1000: i64 = 150;

/// A composition card. `weight` defaults to 1 when absent (Lua `c.weight or 1`).
#[derive(Clone, Debug)]
pub struct Card {
    pub id: String,
    pub weight: Option<i64>,
}

impl Card {
    pub fn new(id: &str, weight: i64) -> Card {
        Card { id: id.to_string(), weight: Some(weight) }
    }
    /// Card with no explicit weight -> counts as 1 (mirrors Lua nil weight).
    pub fn unweighted(id: &str) -> Card {
        Card { id: id.to_string(), weight: None }
    }
    fn w(&self) -> i64 {
        self.weight.unwrap_or(1)
    }
}

/// The ad ground truth. Mirrors sim/funnel.lua's truth table; `hold_given_stop_ppm`
/// is the OPTIONAL hold gate (None == no hold stage).
#[derive(Clone, Debug, PartialEq)]
pub struct Truth {
    pub hook_ppm: i64,
    pub hold_given_stop_ppm: Option<i64>,
    pub click_given_stop_ppm: i64,
    pub cvr_ppm: i64,
    pub aov_cents: i64,
}

pub fn total_weight(cards: &[Card]) -> i64 {
    let mut w = 0;
    for c in cards {
        w += c.w();
    }
    w
}

pub fn over_by(cards: &[Card], capacity: i64) -> i64 {
    let over = total_weight(cards) - capacity;
    if over < 0 {
        0
    } else {
        over
    }
}

pub fn legibility_x1000(over: i64) -> i64 {
    if over <= 0 {
        return 1000;
    }
    let mut p = 1000 - PENALTY_PER_OVER_X1000 * over;
    if p < PENALTY_FLOOR_X1000 {
        p = PENALTY_FLOOR_X1000;
    }
    p
}

/// Clutter scales hook + hold only (legibility), never click intent or cvr.
pub fn apply_overload(truth: &Truth, over: i64) -> Truth {
    let m = legibility_x1000(over);
    Truth {
        hook_ppm: truth.hook_ppm * m / 1000,
        hold_given_stop_ppm: truth.hold_given_stop_ppm.map(|h| h * m / 1000),
        click_given_stop_ppm: truth.click_given_stop_ppm,
        cvr_ppm: truth.cvr_ppm,
        aov_cents: truth.aov_cents,
    }
}

// ------------------------------------------------------- combination wear

/// Set-semantics key: sorted card ids. Sorting is deterministic (string ids;
/// Rust str Ord == byte-wise, matching Lua table.sort on strings).
pub fn combo_key(cards: &[Card]) -> String {
    let mut ids: Vec<&str> = cards.iter().map(|c| c.id.as_str()).collect();
    ids.sort();
    ids.join("+")
}

/// Reuse ledger for composed sets. Never iterated (insert/lookup only), so
/// determinism holds; BTreeMap chosen to remove any doubt.
#[derive(Clone, Debug, Default)]
pub struct ComboBook {
    pub uses: BTreeMap<String, i64>,
}

pub fn new_combo_book() -> ComboBook {
    ComboBook { uses: BTreeMap::new() }
}

pub fn combo_used(book: &mut ComboBook, cards: &[Card]) {
    let key = combo_key(cards);
    *book.uses.entry(key).or_insert(0) += 1;
}

/// Fatigue-rate multiplier for this exact combination (x1000, capped).
pub fn combo_rate_x1000(book: &ComboBook, cards: &[Card]) -> i64 {
    let uses = *book.uses.get(&combo_key(cards)).unwrap_or(&0);
    let mut rate = 1000 + COMBO_RATE_PER_USE_X1000 * uses;
    if rate > COMBO_RATE_CAP_X1000 {
        rate = COMBO_RATE_CAP_X1000;
    }
    rate
}

/// Total wear rate fed into Fatigue.expose: resonance rate x combo rate.
pub fn total_fatigue_rate_x1000(resonance_rate_x1000: i64, combo_rate_x1000: i64) -> i64 {
    resonance_rate_x1000 * combo_rate_x1000 / 1000
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(id: &str, w: i64) -> Card {
        Card::new(id, w)
    }

    // ---- all asserts below are luajit goldens from sim/composer.lua ----

    #[test]
    fn weight_and_capacity() {
        let light = vec![card("hook_a", 2), card("visual_b", 2), card("fmt_c", 1)];
        assert_eq!(total_weight(&light), 5);
        // nil weights default to 1 each (Lua `c.weight or 1`)
        assert_eq!(
            total_weight(&[Card::unweighted("a"), Card::unweighted("b")]),
            2
        );
        assert_eq!(over_by(&light, 6), 0);
        let heavy = vec![
            card("hook_a", 2),
            card("visual_b", 3),
            card("fmt_c", 2),
            card("offer_d", 2),
        ];
        assert_eq!(over_by(&heavy, 6), 3);
    }

    #[test]
    fn legibility_monotone_floored() {
        assert_eq!(legibility_x1000(-1), 1000);
        assert_eq!(legibility_x1000(0), 1000);
        assert_eq!(legibility_x1000(1), 880);
        assert_eq!(legibility_x1000(2), 760);
        assert_eq!(legibility_x1000(3), 640);
        assert_eq!(legibility_x1000(4), 600); // 520 floored to 600
        assert_eq!(legibility_x1000(5), 600);
        assert_eq!(legibility_x1000(50), 600);
        assert_eq!(PENALTY_FLOOR_X1000, 600);
        assert_eq!(COMBO_RATE_CAP_X1000, 2000);
    }

    #[test]
    fn overload_hits_hook_and_hold_only() {
        let truth = Truth {
            hook_ppm: 280000,
            hold_given_stop_ppm: Some(450000),
            click_given_stop_ppm: 78571,
            cvr_ppm: 24000,
            aov_cents: 4500,
        };
        let cl = apply_overload(&truth, 2);
        assert_eq!(cl.hook_ppm, 212800);
        assert_eq!(cl.hold_given_stop_ppm, Some(342000));
        assert_eq!(cl.click_given_stop_ppm, 78571);
        assert_eq!(cl.cvr_ppm, 24000);
        assert_eq!(cl.aov_cents, 4500);

        let cl3 = apply_overload(&truth, 3);
        assert_eq!(cl3.hook_ppm, 179200);
        assert_eq!(cl3.hold_given_stop_ppm, Some(288000));

        let clean = apply_overload(&truth, 0);
        assert_eq!(clean.hook_ppm, 280000);
        assert_eq!(clean.hold_given_stop_ppm, Some(450000));

        // optional hold gate absent -> stays absent, draw-count preserving
        let nohold = Truth {
            hook_ppm: 300000,
            hold_given_stop_ppm: None,
            click_given_stop_ppm: 50000,
            cvr_ppm: 20000,
            aov_cents: 3000,
        };
        let nh = apply_overload(&nohold, 2);
        assert_eq!(nh.hook_ppm, 228000);
        assert_eq!(nh.hold_given_stop_ppm, None);
    }

    #[test]
    fn combo_key_is_a_set() {
        let abc = combo_key(&[card("a", 1), card("b", 1), card("c", 1)]);
        let cab = combo_key(&[card("c", 1), card("a", 1), card("b", 1)]);
        assert_eq!(abc, "a+b+c");
        assert_eq!(cab, "a+b+c");
        assert_ne!(
            combo_key(&[card("a", 1), card("b", 1)]),
            combo_key(&[card("a", 1), card("c", 1)])
        );
    }

    #[test]
    fn combo_echo_fatigue() {
        let mut book = new_combo_book();
        let combo = vec![card("hook_a", 1), card("visual_b", 1), card("fmt_c", 1)];
        assert_eq!(combo_rate_x1000(&book, &combo), 1000);
        combo_used(&mut book, &combo);
        combo_used(&mut book, &combo);
        assert_eq!(combo_rate_x1000(&book, &combo), 1300);
        combo_used(&mut book, &combo);
        assert_eq!(combo_rate_x1000(&book, &combo), 1450);
        for _ in 0..20 {
            combo_used(&mut book, &combo);
        }
        assert_eq!(combo_rate_x1000(&book, &combo), 2000); // capped
        let remix = vec![card("hook_a", 1), card("visual_b", 1), card("fmt_NEW", 1)];
        assert_eq!(combo_rate_x1000(&book, &remix), 1000); // one swap = fresh combo
    }

    #[test]
    fn total_fatigue_rate_composes() {
        assert_eq!(total_fatigue_rate_x1000(1500, 1200), 1800);
        assert_eq!(total_fatigue_rate_x1000(1000, 1000), 1000);
        assert_eq!(total_fatigue_rate_x1000(1333, 1450), 1932);
    }
}
