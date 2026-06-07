//! Hardcoded demo content — the 18-card, 2-lane world used for local dev and tests.
use crate::content;

/// A small validated world: 18 cards, 2 lanes (pattern shift between clients).
/// Byte-for-byte transcription of Game.demo_pack().
pub fn demo_pack() -> content::Content {
    fn card(id: &str, kind: &str, rarity: &str, weight: i64, aspects: &[(&str, i64)], name: &str) -> content::Card {
        content::Card {
            id: id.into(),
            kind: kind.into(),
            rarity: rarity.into(),
            aspects: aspects.iter().map(|(n, p)| content::Aspect { name: (*n).into(), pts: *p }).collect(),
            strings: content::Strings::en(name),
            effect: None,
            weight: Some(weight),
        }
    }
    fn lane(id: &str, stage: &str, audience: i64, name: &str) -> content::Lane {
        content::Lane { id: id.into(), stage: stage.into(), audience, strings: content::Strings::en(name) }
    }
    fn client(id: &str, vertical: &str, mult: Vec<i64>, name: &str, lane: &str) -> content::Client {
        content::Client {
            id: id.into(),
            multiples: mult,
            base_target_cents: 80000,
            spend_floor_cents: 60000,
            fee_cents: 30000,
            strings: content::Strings::en(name),
            vertical: Some(vertical.into()),
            lane: Some(lane.into()),
        }
    }
    content::Content {
        content_format: 1,
        retired_ids: Vec::new(),
        cards: vec![
            card("hook_pain", "hook", "common", 2, &[("problem", 3), ("urgency", 1)], "Pain Point"),
            card("hook_founder", "hook", "common", 2, &[("trust", 2), ("novelty", 1)], "Founder Story"),
            card("hook_stat", "hook", "common", 2, &[("novelty", 2), ("mechanism", 1)], "Stat Shock"),
            card("hook_fomo", "hook", "common", 2, &[("urgency", 2), ("scarcity", 2)], "FOMO Drop"),
            card("vis_ugc", "visual", "common", 2, &[("social_proof", 2), ("trust", 1)], "UGC Selfie"),
            card("vis_demo", "visual", "common", 2, &[("mechanism", 2), ("solution", 1)], "Demo Closeup"),
            card("vis_before", "visual", "common", 2, &[("comparison", 2), ("mechanism", 1)], "Before/After"),
            card("vis_cine", "visual", "uncommon", 4, &[("novelty", 2)], "Cinematic Pour"),
            card("fmt_video", "format", "common", 1, &[("novelty", 1)], "Short Video"),
            card("fmt_carousel", "format", "common", 1, &[("comparison", 1)], "Carousel"),
            card("off_bundle", "offer", "uncommon", 1, &[("offer_strength", 3)], "Bundle & Save"),
            card("off_trial", "offer", "common", 1, &[("offer_strength", 2), ("trust", 1)], "Free Trial"),
            card("hook_question", "hook", "common", 2, &[("problem", 2), ("urgency", 1)], "Question Hook"),
            card("hook_social", "hook", "uncommon", 3, &[("social_proof", 2), ("trust", 1)], "Social Proof"),
            card("vis_testimonial", "visual", "common", 2, &[("social_proof", 2), ("trust", 2)], "Testimonial"),
            card("vis_result", "visual", "uncommon", 3, &[("solution", 2), ("comparison", 1)], "Result Reveal"),
            card("fmt_story", "format", "common", 1, &[("novelty", 1), ("scarcity", 1)], "Stories"),
            card("off_discount", "offer", "uncommon", 2, &[("offer_strength", 2), ("scarcity", 2)], "Flash Discount"),
        ],
        lanes: vec![
            lane("lane_cold", "PROBLEM", 40000, "Cold — Problem Aware"),
            lane("lane_warm", "PRODUCT", 40000, "Warm — Product Aware"),
        ],
        clients: vec![
            client("copper_char", "cookware", vec![1450, 1600, 1750], "Copper & Char", "lane_cold"),
            client("tundra_boots", "boots", vec![1600, 1750, 1850], "Tundra Boots", "lane_warm"),
        ],
    }
}
