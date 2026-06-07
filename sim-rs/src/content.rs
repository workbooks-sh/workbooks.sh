//! Content schema + validator. Port of sim/content.lua (docs/02-technical.md §6;
//! cards.md §4).
//!
//! Content is DATA: cards/lanes/clients as plain tables with stable string IDs
//! (never reused — retired list enforced), ordered {name, pts} aspect lists from
//! the resonance taxonomy, a locale-ready string layer (en required from day
//! one), and behavior only as NAMED EFFECT REFS against a whitelist.
//!
//! The validator is a TOOL (boot/CI), not sim-tick code. Error ORDER is
//! unspecified; PRESENCE is the contract (mirrors the Lua spec). It performs no
//! rng, no floats — only enum membership, integer ranges, id rules, and the
//! locale check.
//!
//! TWO LUA-ONLY PIECES INTENTIONALLY OMITTED (no Rust analog, both subsumed by
//! the Rust type system):
//!   - `load_string`: Lua `loadstring`+`setfenv` sandbox that EVALS content
//!     source in an empty environment. Rust has no embedded Lua interpreter;
//!     packs are constructed as the typed data below (the integrate phase / a
//!     future serde loader owns ingestion). There is no code to eval.
//!   - `scan_no_functions` (the Apple 2.5.2 data-only law): rejected function
//!     VALUES embedded in a Lua-loaded table. A Rust content struct cannot hold
//!     a function value, so the law is enforced statically — the deep scan is a
//!     no-op here.
//! Cross-validated vs luajit goldens (see #[cfg(test)] / /tmp/content_golden.lua).
use crate::resonance::{ASPECTS, STAGES};
use std::collections::HashSet;

/// Valid card kinds (mirrors Content.KINDS; a Lua set — order is not semantic).
pub const KINDS: [&str; 5] = ["hook", "visual", "format", "offer", "modifier"];
/// Valid rarities (mirrors Content.RARITIES).
pub const RARITIES: [&str; 4] = ["common", "uncommon", "rare", "legendary"];
/// Named behavior refs; implementations live in shipped code (mirrors
/// Content.EFFECTS). Card behavior is ONLY ever one of these strings — never
/// inline code.
pub const EFFECTS: [&str; 4] = [
    "aov_plus_bundle",
    "aov_plus_subscription",
    "extra_op_token",
    "fatigue_slow_onbrand",
];

// ----------------------------------------------------------------- data shape

/// Locale string bundle for one language. `name` required + non-empty; `flavor`
/// optional player copy.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Locale {
    pub name: String,
    pub flavor: Option<String>,
}

/// Locale-ready string layer. `en` required from day one (validated). Modeled as
/// Option so a malformed pack (missing en) is representable and catchable —
/// exactly the case the validator exists to reject.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Strings {
    pub en: Option<Locale>,
}

impl Strings {
    /// Convenience: a strings layer with just an English name.
    pub fn en(name: &str) -> Strings {
        Strings { en: Some(Locale { name: name.to_string(), flavor: None }) }
    }
}

/// One typed aspect tag: a name from the resonance taxonomy + integer points.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Aspect {
    pub name: String,
    pub pts: i64,
}

/// A content card. `effect`/`weight` are optional; everything else is validated.
/// (`weight` is consumed by pack weighting downstream; the validator ignores it,
/// mirroring the Lua which validates only id/kind/rarity/aspects/strings/effect.)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Card {
    pub id: String,
    pub kind: String,
    pub rarity: String,
    pub aspects: Vec<Aspect>,
    pub strings: Strings,
    pub effect: Option<String>,
    pub weight: Option<i64>,
}

/// A lane = an audience at a Schwartz stage. (Distinct from `resonance::Lane`,
/// which is the per-(run,client,stage) hidden-weights object.)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Lane {
    pub id: String,
    pub stage: String,
    pub audience: i64,
    pub strings: Strings,
}

/// A client brief. cents are integer cents; multiples are x1000 integers.
/// `vertical`/`lane` are consumed downstream; the validator ignores them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Client {
    pub id: String,
    pub multiples: Vec<i64>,
    pub base_target_cents: i64,
    pub spend_floor_cents: i64,
    pub fee_cents: i64,
    pub strings: Strings,
    pub vertical: Option<String>,
    pub lane: Option<String>,
}

/// A content pack (mirrors the table the Lua loader returns / validate consumes).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Content {
    pub content_format: i64,
    pub retired_ids: Vec<String>,
    pub cards: Vec<Card>,
    pub lanes: Vec<Lane>,
    pub clients: Vec<Client>,
}

/// One validation error. `path` locates the offender; `msg` names the rule.
/// (Both carry the offending id where relevant — the test contract matches on
/// either field, mirroring the Lua `has_err`.)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ValidationError {
    pub path: String,
    pub msg: String,
}

// ------------------------------------------------------------------ validate

fn fail(errors: &mut Vec<ValidationError>, path: &str, msg: String) {
    errors.push(ValidationError { path: path.to_string(), msg });
}

/// `^[a-z][a-z0-9_]*$` — lowercase snake_case, leading letter.
fn valid_id(id: &str) -> bool {
    let mut chars = id.chars();
    match chars.next() {
        Some(c) if c.is_ascii_lowercase() => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

fn check_strings(strings: &Strings, path: &str, errors: &mut Vec<ValidationError>) {
    let ok = matches!(&strings.en, Some(l) if !l.name.is_empty());
    if !ok {
        fail(errors, path, "strings.en.name required (locale layer is day-one)".into());
    }
}

fn check_id<'a>(
    id: &'a str,
    path: &str,
    seen: &mut HashSet<&'a str>,
    retired: &HashSet<&'a str>,
    errors: &mut Vec<ValidationError>,
) {
    if !valid_id(id) {
        fail(errors, path, format!("id must be lowercase snake_case, got: {}", id));
        return;
    }
    if seen.contains(id) {
        fail(errors, path, format!("duplicate id: {}", id));
    }
    if retired.contains(id) {
        fail(errors, path, format!("retired id may never return: {}", id));
    }
    seen.insert(id);
}

fn check_card<'a>(
    card: &'a Card,
    path: &str,
    seen: &mut HashSet<&'a str>,
    retired: &HashSet<&'a str>,
    errors: &mut Vec<ValidationError>,
) {
    check_id(&card.id, path, seen, retired, errors);
    if !KINDS.contains(&card.kind.as_str()) {
        fail(errors, path, format!("unknown kind: {}", card.kind));
    }
    if !RARITIES.contains(&card.rarity.as_str()) {
        fail(errors, path, format!("unknown rarity: {}", card.rarity));
    }
    if card.aspects.is_empty() || card.aspects.len() > 4 {
        fail(errors, path, "aspects must be an ordered list of 1..4 entries".into());
    } else {
        let mut used: HashSet<&str> = HashSet::new();
        for (i, e) in card.aspects.iter().enumerate() {
            let apath = format!("{}.aspects[{}]", path, i + 1);
            if !ASPECTS.contains(&e.name.as_str()) {
                fail(errors, &apath, format!("unknown aspect: {}", e.name));
            }
            if used.contains(e.name.as_str()) {
                fail(errors, &apath, format!("duplicate aspect on card: {}", e.name));
            }
            used.insert(e.name.as_str());
            if e.pts < 1 || e.pts > 5 {
                fail(errors, &apath, "pts must be an integer 1..5".into());
            }
        }
    }
    check_strings(&card.strings, &format!("{}.strings", path), errors);
    if let Some(effect) = &card.effect {
        if !EFFECTS.contains(&effect.as_str()) {
            fail(errors, path, format!("unknown effect ref: {}", effect));
        }
    }
}

/// Validate a content pack. Returns `(ok, errors)`; `ok == errors.is_empty()`.
/// Error order is unspecified (mirrors the Lua); presence is the contract.
pub fn validate(content: &Content) -> (bool, Vec<ValidationError>) {
    let mut errors: Vec<ValidationError> = Vec::new();

    if content.content_format < 1 {
        fail(&mut errors, "$.content_format", "content_format must be a positive integer".into());
    }

    // (scan_no_functions / data-only law: enforced by the type system — N/A.)

    let retired: HashSet<&str> = content.retired_ids.iter().map(|s| s.as_str()).collect();
    let mut seen: HashSet<&str> = HashSet::new();

    for (i, card) in content.cards.iter().enumerate() {
        let path = format!("$.cards[{}] ({})", i + 1, card.id);
        check_card(card, &path, &mut seen, &retired, &mut errors);
    }

    for (i, lane) in content.lanes.iter().enumerate() {
        let path = format!("$.lanes[{}] ({})", i + 1, lane.id);
        check_id(&lane.id, &path, &mut seen, &retired, &mut errors);
        if !STAGES.contains(&lane.stage.as_str()) {
            fail(&mut errors, &path, format!("invalid stage: {}", lane.stage));
        }
        if lane.audience < 1 {
            fail(&mut errors, &path, "audience must be a positive integer".into());
        }
        check_strings(&lane.strings, &format!("{}.strings", path), &mut errors);
    }

    for (i, client) in content.clients.iter().enumerate() {
        let path = format!("$.clients[{}] ({})", i + 1, client.id);
        check_id(&client.id, &path, &mut seen, &retired, &mut errors);
        if client.multiples.is_empty() {
            fail(&mut errors, &path, "multiples must be a non-empty list".into());
        } else {
            for (j, m) in client.multiples.iter().enumerate() {
                if *m < 1 {
                    fail(
                        &mut errors,
                        &format!("{}.multiples[{}]", path, j + 1),
                        "multiple must be a positive integer (x1000)".into(),
                    );
                }
            }
        }
        for (field, v) in [
            ("base_target_cents", client.base_target_cents),
            ("spend_floor_cents", client.spend_floor_cents),
            ("fee_cents", client.fee_cents),
        ] {
            if v < 0 {
                fail(&mut errors, &path, format!("{} must be a non-negative integer", field));
            }
        }
        check_strings(&client.strings, &format!("{}.strings", path), &mut errors);
    }

    (errors.is_empty(), errors)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Goldens from luajit on sim/content.lua (/tmp/content_golden.lua): each
    // single mutation yields exactly ONE error carrying the named needle; the
    // valid pack yields zero. Error order is unspecified, so we assert (ok,
    // count, presence) — the same contract test/sim/test_content.lua enforces.

    fn valid_pack() -> Content {
        Content {
            content_format: 1,
            retired_ids: vec!["hook_old_meme".into()],
            cards: vec![
                Card {
                    id: "hook_pain_point".into(),
                    kind: "hook".into(),
                    rarity: "common".into(),
                    aspects: vec![
                        Aspect { name: "problem".into(), pts: 3 },
                        Aspect { name: "urgency".into(), pts: 1 },
                    ],
                    strings: Strings {
                        en: Some(Locale {
                            name: "Pain Point Open".into(),
                            flavor: Some("Lead with the ouch.".into()),
                        }),
                    },
                    effect: None,
                    weight: None,
                },
                Card {
                    id: "offer_bundle".into(),
                    kind: "offer".into(),
                    rarity: "uncommon".into(),
                    aspects: vec![Aspect { name: "offer_strength".into(), pts: 3 }],
                    strings: Strings::en("Bundle & Save"),
                    effect: Some("aov_plus_bundle".into()),
                    weight: None,
                },
            ],
            lanes: vec![Lane {
                id: "cold_problem".into(),
                stage: "PROBLEM".into(),
                audience: 50000,
                strings: Strings::en("Cold — Problem Aware"),
            }],
            clients: vec![Client {
                id: "copper_char".into(),
                multiples: vec![1000, 1500, 2000],
                base_target_cents: 50000,
                spend_floor_cents: 20000,
                fee_cents: 30000,
                strings: Strings::en("Copper & Char"),
                vertical: Some("cookware".into()),
                lane: None,
            }],
        }
    }

    fn has_err(errors: &[ValidationError], needle: &str) -> bool {
        errors.iter().any(|e| e.msg.contains(needle) || e.path.contains(needle))
    }

    /// Run validate after a mutation; assert ok==false, exactly one error, needle present.
    fn one_err(mutate: impl FnOnce(&mut Content), needle: &str) {
        let mut p = valid_pack();
        mutate(&mut p);
        let (ok, errors) = validate(&p);
        assert!(!ok, "expected invalid for needle {}", needle);
        assert_eq!(errors.len(), 1, "expected exactly one error for needle {}: {:?}", needle, errors);
        assert!(has_err(&errors, needle), "missing needle {} in {:?}", needle, errors);
    }

    #[test]
    fn valid_pack_passes() {
        let (ok, errors) = validate(&valid_pack());
        assert!(ok);
        assert_eq!(errors.len(), 0);
    }

    #[test]
    fn id_rules() {
        one_err(|p| p.cards[1].id = "hook_pain_point".into(), "hook_pain_point"); // duplicate
        one_err(|p| p.cards[0].id = "Hook-Pain!".into(), "Hook-Pain!"); // non-snake
        one_err(|p| p.cards[0].id = "hook_old_meme".into(), "retired"); // retired
    }

    #[test]
    fn aspect_rules() {
        one_err(|p| p.cards[0].aspects[0].name = "vibes".into(), "vibes");
        one_err(|p| p.cards[0].aspects[0].pts = 99, "pts");
        one_err(|p| p.cards[0].aspects[0].pts = 0, "pts");
        one_err(|p| p.cards[0].aspects.clear(), "aspects");
        one_err(
            |p| {
                p.cards[0].aspects = vec![
                    Aspect { name: "problem".into(), pts: 1 },
                    Aspect { name: "solution".into(), pts: 1 },
                    Aspect { name: "trust".into(), pts: 1 },
                    Aspect { name: "urgency".into(), pts: 1 },
                    Aspect { name: "novelty".into(), pts: 1 },
                ]
            },
            "aspects",
        ); // 5 > 4
        one_err(
            |p| {
                p.cards[0].aspects = vec![
                    Aspect { name: "problem".into(), pts: 2 },
                    Aspect { name: "problem".into(), pts: 1 },
                ]
            },
            "duplicate",
        );
    }

    #[test]
    fn enum_and_strings_rules() {
        one_err(|p| p.cards[0].kind = "jingle".into(), "jingle");
        one_err(|p| p.cards[0].rarity = "mythic".into(), "mythic");
        one_err(|p| p.cards[0].strings.en = None, "en"); // missing en.name
        one_err(|p| p.cards[0].strings.en = Some(Locale { name: String::new(), flavor: None }), "en"); // empty name
    }

    #[test]
    fn effect_whitelist() {
        one_err(|p| p.cards[1].effect = Some("win_the_game".into()), "win_the_game");
    }

    #[test]
    fn lane_and_client_rules() {
        one_err(|p| p.lanes[0].stage = "LUKEWARM".into(), "LUKEWARM");
        one_err(|p| p.lanes[0].audience = 0, "audience");
        one_err(|p| p.clients[0].multiples.clear(), "multiples");
        one_err(|p| p.clients[0].base_target_cents = -5, "base_target_cents");
        one_err(|p| p.clients[0].multiples = vec![1000, 0], "multiple");
    }

    #[test]
    fn content_format_must_be_positive() {
        one_err(|p| p.content_format = 0, "content_format");
    }

    #[test]
    fn membership_tables_match_lua() {
        let mut k = KINDS.to_vec();
        k.sort();
        assert_eq!(k, vec!["format", "hook", "modifier", "offer", "visual"]);
        let mut r = RARITIES.to_vec();
        r.sort();
        assert_eq!(r, vec!["common", "legendary", "rare", "uncommon"]);
        let mut e = EFFECTS.to_vec();
        e.sort();
        assert_eq!(
            e,
            vec![
                "aov_plus_bundle",
                "aov_plus_subscription",
                "extra_op_token",
                "fatigue_slow_onbrand"
            ]
        );
    }
}
