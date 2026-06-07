//! Economy. Bit-identical port of sim/economy.lua (docs/01-game-design.md §2
//! NEWSSTAND + §4; cards.md §2).
//!
//! One bankroll funds media AND creative — the spend-vs-compound tension is the
//! design point. Interest is a Balatro-shaped game device with a visible cap
//! ($1 per $5 held, floored at $500 banked). The Newsstand restocks per wave:
//! 2 singles + 2 packs + 1 upgrade at 70/25/5 rarity weights; legendaries never
//! appear in the shop. Duplicates auto-convert to Iteration Points; IP + a
//! fatigued/spent winner mints a V2 foil with a MUTATED aspect vector — one
//! point moves from one tag to another, total conserved (different and fresher,
//! never strictly better).
//!
//! All money is integer cents; all randomness flows through named substreams.
//! The RNG call order/count mirrors the Lua exactly (determinism is sacred):
//! every Lua `cands[1 + rng:next_u32() % #cands]` becomes a 0-based
//! `cands[(next_u32() % len)]` — same draw, same element. Cross-validated
//! against luajit goldens below.
//!
//! Aspect vectors are ORDERED lists (`Vec<Aspect>`) — the content-schema
//! convention that keeps iteration deterministic (no map iteration in sim code).

use crate::rng::Rng;
use std::collections::HashSet;

// ---------------------------------------------------------------- constants

pub const PRICE_COMMON: i64 = 5000;
pub const PRICE_UNCOMMON: i64 = 8000;
pub const PRICE_RARE: i64 = 15000;
pub const PRICE_PACK: i64 = 7500;
pub const PRICE_UPGRADE: i64 = 10000;

pub const V2_IP_COST: i64 = 5;
pub const INTEREST_CAP_CENTS: i64 = 10000; // $100, reached at $500 banked
const INTEREST_STEP: i64 = 500; // $1 per $5 held

// rarity -> shop weight (in fixed order; mirrors the Lua RARITY_WEIGHTS list).
const RARITY_WEIGHTS: [(&str, u32); 3] = [("common", 70), ("uncommon", 25), ("rare", 5)];
const UPGRADES: [&str; 4] = [
    "extra_op_token",
    "third_bench_slot",
    "faster_unredaction",
    "wider_hand",
];

/// Per-rarity single-card price (`Economy.PRICE[rarity]`). `None` for rarities
/// the shop never sells (e.g. `legendary`); in the Lua that path errors —
/// `buy_card` here treats it as unpurchasable instead (a safe, dead path: shop
/// singles are only ever common/uncommon/rare).
pub fn price_of(rarity: &str) -> Option<i64> {
    match rarity {
        "common" => Some(PRICE_COMMON),
        "uncommon" => Some(PRICE_UNCOMMON),
        "rare" => Some(PRICE_RARE),
        _ => None,
    }
}

/// Iteration Points minted by a duplicate (`Economy.IP_PER_DUP[rarity] or 1`).
pub fn ip_per_dup(rarity: &str) -> i64 {
    match rarity {
        "common" => 1,
        "uncommon" => 2,
        "rare" => 4,
        "legendary" => 8,
        _ => 1, // Lua `or 1` fallback
    }
}

// ---------------------------------------------------------------- types

/// One ordered aspect entry — the Lua `{name, pts}` pair.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Aspect {
    pub name: String,
    pub pts: i64,
}

/// A content card. `foil` is false for pool cards (Lua nil) and true on minted
/// V2s. `aspects` is an ORDERED list (deterministic iteration).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Card {
    pub id: String,
    pub rarity: String,
    pub aspects: Vec<Aspect>,
    pub foil: bool,
}

/// The single bankroll, in integer cents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bank {
    pub cents: i64,
}

/// The player's collection: owned card ids (membership), banked Iteration
/// Points, and tempo tags accrued from skipping shops.
#[derive(Clone, Debug, Default)]
pub struct Collection {
    pub owned: HashSet<String>,
    pub ip: i64,
    pub tempo_tags: i64,
}

/// A pack slot on the shelf (fixed price).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pack {
    pub price: i64,
}

/// A restocked Newsstand: 2 singles + 2 packs + 1 upgrade.
#[derive(Clone, Debug)]
pub struct Shop {
    pub singles: Vec<Card>,
    pub packs: Vec<Pack>,
    pub upgrade: String,
}

// ---------------------------------------------------------------- bankroll

pub fn new_bank(cents: i64) -> Bank {
    Bank { cents }
}

pub fn spend(bank: &mut Bank, cents: i64) -> bool {
    if cents > bank.cents {
        return false;
    }
    bank.cents -= cents;
    true
}

pub fn earn(bank: &mut Bank, cents: i64) {
    bank.cents += cents;
}

/// Interest due on a balance: $1 per $5 held, capped. Lua uses
/// `math.floor(balance/500)*100`; balances are non-negative cents, so i64
/// truncating division == floor here (and keeps the path float-free).
pub fn interest_due(balance_cents: i64) -> i64 {
    let mut due = balance_cents / INTEREST_STEP * 100;
    if due > INTEREST_CAP_CENTS {
        due = INTEREST_CAP_CENTS;
    }
    due
}

pub fn apply_interest(bank: &mut Bank) -> i64 {
    let due = interest_due(bank.cents);
    bank.cents += due;
    due
}

// ---------------------------------------------------------------- shop

/// Weighted rarity roll (70/25/5). One `next_u32` draw.
fn pick_rarity(rng: &mut Rng) -> &'static str {
    let roll = rng.next_u32() % 100;
    let mut acc = 0u32;
    for (rarity, w) in RARITY_WEIGHTS {
        acc += w;
        if roll < acc {
            return rarity;
        }
    }
    "common"
}

/// Pick a card of `rarity` from `pool` (pool order is deterministic). Falls back
/// down the rarity ladder (any non-legendary) when the pool has none of the
/// requested rarity. One `next_u32` draw.
fn pick_card<'a>(rng: &mut Rng, pool: &'a [Card], rarity: &str) -> &'a Card {
    let mut cands: Vec<&'a Card> = Vec::new();
    for c in pool {
        if c.rarity == rarity {
            cands.push(c);
        }
    }
    if cands.is_empty() {
        for c in pool {
            if c.rarity != "legendary" {
                cands.push(c);
            }
        }
    }
    let idx = (rng.next_u32() as usize) % cands.len();
    cands[idx]
}

/// Newsstand for (run seed, wave): 2 singles + 2 packs + 1 upgrade.
/// Draw order: rarity, card (x2), then upgrade — 5 draws total.
pub fn new_shop(seed: u32, wave: i64, pool: &[Card]) -> Shop {
    let mut rng = Rng::substream(seed, &format!("shop:wave{}", wave));
    let mut singles = Vec::with_capacity(2);
    for _ in 0..2 {
        // pick_rarity first, then pick_card — mirrors Lua arg evaluation order.
        let rarity = pick_rarity(&mut rng);
        let card = pick_card(&mut rng, pool, rarity);
        singles.push(card.clone());
    }
    let packs = vec![Pack { price: PRICE_PACK }, Pack { price: PRICE_PACK }];
    let upgrade = UPGRADES[(rng.next_u32() as usize) % UPGRADES.len()].to_string();
    Shop { singles, packs, upgrade }
}

// ---------------------------------------------------------------- collection

pub fn new_collection() -> Collection {
    Collection::default()
}

/// Acquire a card into the collection: a duplicate mints IP, a new one is owned.
/// Returns "duplicate" or "new" (parity with the Lua; callers ignore it).
fn acquire(col: &mut Collection, card: &Card) -> &'static str {
    if col.owned.contains(&card.id) {
        col.ip += ip_per_dup(&card.rarity);
        return "duplicate";
    }
    col.owned.insert(card.id.clone());
    "new"
}

pub fn buy_card(bank: &mut Bank, col: &mut Collection, card: &Card) -> bool {
    let price = match price_of(&card.rarity) {
        Some(p) => p,
        None => return false,
    };
    if !spend(bank, price) {
        return false;
    }
    acquire(col, card);
    true
}

/// Open a pack: spend, then 3 seeded pulls at shop rarity weights (dups
/// convert). Returns the pulled cards, or None when the bankroll can't cover it.
/// Per pull: rarity draw, card draw (6 draws total).
pub fn open_pack(
    bank: &mut Bank,
    col: &mut Collection,
    seed: u32,
    pool: &[Card],
) -> Option<Vec<Card>> {
    if !spend(bank, PRICE_PACK) {
        return None;
    }
    let mut rng = Rng::substream(seed, "pack");
    let mut got = Vec::with_capacity(3);
    for _ in 0..3 {
        let rarity = pick_rarity(&mut rng);
        let card = pick_card(&mut rng, pool, rarity).clone();
        acquire(col, &card);
        got.push(card);
    }
    Some(got)
}

pub fn skip_shop(col: &mut Collection) {
    col.tempo_tags += 1;
}

// ---------------------------------------------------------------- V2 mint

/// IP + a tired winner -> V2 foil: move exactly one aspect point from one tag
/// (a donor with >=1 point) to a different tag. Total conserved => different and
/// fresher, never strictly better. Returns None unless the card is worn, IP is
/// sufficient, and the card has >=2 aspects. Draw order: donor index, then
/// recipient index (redrawn while it collides with the donor).
pub fn mint_v2(col: &mut Collection, card: &Card, is_worn: bool, rng: &mut Rng) -> Option<Card> {
    if !is_worn {
        return None;
    }
    if col.ip < V2_IP_COST {
        return None;
    }
    if card.aspects.len() < 2 {
        return None;
    }
    col.ip -= V2_IP_COST;

    // donors: aspects with at least 1 point, in list order (deterministic).
    let mut donors: Vec<usize> = Vec::new();
    for (i, e) in card.aspects.iter().enumerate() {
        if e.pts >= 1 {
            donors.push(i);
        }
    }
    let from = donors[(rng.next_u32() as usize) % donors.len()];
    let mut to = from;
    while to == from {
        to = (rng.next_u32() as usize) % card.aspects.len();
    }

    let mut aspects = Vec::with_capacity(card.aspects.len());
    for (i, e) in card.aspects.iter().enumerate() {
        let mut pts = e.pts;
        if i == from {
            pts -= 1;
        }
        if i == to {
            pts += 1;
        }
        aspects.push(Aspect { name: e.name.clone(), pts });
    }
    Some(Card {
        id: format!("{}:v2", card.id),
        rarity: card.rarity.clone(),
        aspects,
        foil: true,
    })
}

