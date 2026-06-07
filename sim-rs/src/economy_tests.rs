use crate::economy::*;
use crate::rng::Rng;

fn asp(name: &str, pts: i64) -> Aspect {
    Aspect { name: name.into(), pts }
}

fn card(id: &str, rarity: &str, aspects: Vec<Aspect>) -> Card {
    Card { id: id.into(), rarity: rarity.into(), aspects, foil: false }
}

/// The 12 demo-pack cards (id, rarity, aspects), matching golden_economy.lua.
fn demo_pool() -> Vec<Card> {
    vec![
        card("hook_pain", "common", vec![asp("problem", 3), asp("urgency", 1)]),
        card("hook_founder", "common", vec![asp("trust", 2), asp("novelty", 1)]),
        card("hook_stat", "common", vec![asp("novelty", 2), asp("mechanism", 1)]),
        card("hook_fomo", "common", vec![asp("urgency", 2), asp("scarcity", 2)]),
        card("vis_ugc", "common", vec![asp("social_proof", 2), asp("trust", 1)]),
        card("vis_demo", "common", vec![asp("mechanism", 2), asp("solution", 1)]),
        card("vis_before", "common", vec![asp("comparison", 2), asp("mechanism", 1)]),
        card("vis_cine", "uncommon", vec![asp("novelty", 2)]),
        card("fmt_video", "common", vec![asp("novelty", 1)]),
        card("fmt_carousel", "common", vec![asp("comparison", 1)]),
        card("off_bundle", "uncommon", vec![asp("offer_strength", 3)]),
        card("off_trial", "common", vec![asp("offer_strength", 2), asp("trust", 1)]),
    ]
}

// ---- goldens captured from `luajit golden_economy.lua` on sim/economy.lua ----

#[test]
fn interest_matches_luajit() {
    assert_eq!(interest_due(0), 0);
    assert_eq!(interest_due(400), 0);
    assert_eq!(interest_due(499), 0);
    assert_eq!(interest_due(500), 100);
    assert_eq!(interest_due(2500), 500);
    assert_eq!(interest_due(49999), 9900);
    assert_eq!(interest_due(50000), 10000); // cap reached at $500
    assert_eq!(interest_due(100000), 10000); // capped

    let mut b = new_bank(2500);
    assert_eq!(apply_interest(&mut b), 500);
    assert_eq!(b.cents, 3000);
}

#[test]
fn bankroll_matches_luajit() {
    let mut b = new_bank(10000);
    assert!(spend(&mut b, 4000));
    assert_eq!(b.cents, 6000);
    assert!(!spend(&mut b, 999999)); // can't overspend
    assert_eq!(b.cents, 6000);
    earn(&mut b, 1500);
    assert_eq!(b.cents, 7500);
}

#[test]
fn shop_matches_luajit() {
    let pool = demo_pool();

    let s1 = new_shop(7, 1, &pool);
    assert_eq!(s1.singles[0].id, "off_trial");
    assert_eq!(s1.singles[1].id, "fmt_carousel");
    assert_eq!(s1.upgrade, "third_bench_slot");
    assert_eq!(s1.packs.len(), 2);
    assert_eq!(s1.packs[0].price, 7500);
    assert_eq!(s1.packs[1].price, 7500);

    let s2 = new_shop(42, 3, &pool);
    assert_eq!(s2.singles[0].id, "hook_fomo");
    assert_eq!(s2.singles[1].id, "vis_demo");
    assert_eq!(s2.upgrade, "third_bench_slot");
}

#[test]
fn open_pack_matches_luajit() {
    let pool = demo_pool();
    let mut bank = new_bank(60000);
    let mut col = new_collection();
    let got = open_pack(&mut bank, &mut col, 1234, &pool).expect("affordable pack opens");
    assert_eq!(bank.cents, 52500); // 60000 - 7500
    assert_eq!(col.ip, 1); // got3 duplicates got2 (fmt_video, common -> +1 IP)
    assert_eq!(got[0].id, "hook_founder");
    assert_eq!(got[1].id, "fmt_video");
    assert_eq!(got[2].id, "fmt_video");

    // can't open while broke
    let mut broke = new_bank(100);
    assert!(open_pack(&mut broke, &mut col, 1, &pool).is_none());
}

#[test]
fn buy_card_matches_luajit() {
    let mut bank = new_bank(10000);
    let mut col = new_collection();
    let c = card("hook_pain", "common", vec![]);

    assert!(buy_card(&mut bank, &mut col, &c)); // first buy: new
    assert_eq!(bank.cents, 5000);
    assert!(buy_card(&mut bank, &mut col, &c)); // second buy: duplicate
    assert_eq!(bank.cents, 0);
    assert_eq!(col.ip, 1); // dup common -> +1 IP
    assert!(!buy_card(&mut bank, &mut col, &c)); // broke
    assert_eq!(bank.cents, 0);

    let mut bank2 = new_bank(8000);
    let u = card("u", "uncommon", vec![]);
    assert!(buy_card(&mut bank2, &mut col, &u));
    assert_eq!(bank2.cents, 0); // 8000 - 8000
}

#[test]
fn skip_shop_matches_luajit() {
    let mut col = new_collection();
    skip_shop(&mut col);
    skip_shop(&mut col);
    assert_eq!(col.tempo_tags, 2);
}

#[test]
fn mint_v2_matches_luajit() {
    let mut col = new_collection();
    col.ip = 10;
    let c = card("hook_pain", "common", vec![asp("problem", 3), asp("urgency", 1)]);
    let mut rng = Rng::substream(99, "mint");
    let v2 = mint_v2(&mut col, &c, true, &mut rng).expect("worn + IP mints a V2");
    assert_eq!(v2.id, "hook_pain:v2");
    assert!(v2.foil);
    assert_eq!(v2.rarity, "common");
    assert_eq!(col.ip, 5); // 10 - V2_IP_COST(5)
    // one point moved problem -> urgency, total conserved (3+1 == 2+2)
    assert_eq!(v2.aspects, vec![asp("problem", 2), asp("urgency", 2)]);
}

#[test]
fn mint_v2_donor_filtering_matches_luajit() {
    // a 0-point aspect is NOT an eligible donor, but IS an eligible recipient.
    let mut col = new_collection();
    col.ip = 10;
    let c = card("multi", "rare", vec![asp("a", 0), asp("b", 2), asp("c", 1)]);
    let mut rng = Rng::substream(7, "mintzero");
    let v2 = mint_v2(&mut col, &c, true, &mut rng).expect("mints");
    assert_eq!(v2.id, "multi:v2");
    assert_eq!(col.ip, 5);
    // donor was c (1->0), recipient was a (0->1); b untouched. Total conserved.
    assert_eq!(v2.aspects, vec![asp("a", 1), asp("b", 2), asp("c", 0)]);
}

#[test]
fn mint_v2_guards_match_luajit() {
    let c = card("hook_pain", "common", vec![asp("problem", 3), asp("urgency", 1)]);

    let mut col = new_collection();
    col.ip = 10;
    let mut r = Rng::substream(1, "a");
    assert!(mint_v2(&mut col, &c, false, &mut r).is_none()); // not worn
    assert_eq!(col.ip, 10); // not charged when it bails

    let mut col2 = new_collection();
    col2.ip = 4;
    let mut r2 = Rng::substream(1, "a");
    assert!(mint_v2(&mut col2, &c, true, &mut r2).is_none()); // insufficient IP

    let mut col3 = new_collection();
    col3.ip = 10;
    let one = card("x", "common", vec![asp("a", 1)]);
    let mut r3 = Rng::substream(1, "a");
    assert!(mint_v2(&mut col3, &one, true, &mut r3).is_none()); // < 2 aspects
}

#[test]
fn constants_match_luajit() {
    assert_eq!(V2_IP_COST, 5);
    assert_eq!(INTEREST_CAP_CENTS, 10000);
    assert_eq!(price_of("common"), Some(5000));
    assert_eq!(price_of("uncommon"), Some(8000));
    assert_eq!(price_of("rare"), Some(15000));
    assert_eq!(PRICE_PACK, 7500);
    assert_eq!(PRICE_UPGRADE, 10000);
    assert_eq!(ip_per_dup("legendary"), 8);
}
