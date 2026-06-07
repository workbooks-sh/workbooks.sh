//! Naming grammar + seeded brand identity. Port of sim/namegen.lua.
//! rng call order matches the Lua exactly (determinism).
use crate::rng::Rng;
use crate::namegen_data::{bank, ABSTRACT, FORM, TRAITS, BLOCKLIST, Bank};

fn pick<'a>(rng: &mut Rng, list: &[&'a str]) -> &'a str {
    list[(rng.next_u32() as usize) % list.len()]
}

// pattern weights (per mille); traits shift them. keys in fixed order.
const KEYS: [&str; 6] = ["amp", "abstract", "adjnoun", "constructed", "form", "society"];
const BASE: [u32; 6] = [180, 220, 180, 140, 180, 100];

fn weights_for(traits: &[&str]) -> [u32; 6] {
    let mut w = BASE;
    for t in traits {
        match *t {
            "heritage" => { w[0]=220; w[5]=220; w[3]=40; }
            "clinical" => { w[3]=420; w[0]=60; w[5]=40; }
            "playful"  => { w[2]=320; w[5]=60; }
            "premium"  => { w[1]=340; w[4]=80; }
            _ => {}
        }
    }
    w
}

fn pick_pattern(rng: &mut Rng, traits: &[&str]) -> &'static str {
    let w = weights_for(traits);
    let total: u32 = w.iter().sum();
    let roll = rng.next_u32() % total;
    let mut acc = 0;
    for i in 0..6 {
        acc += w[i];
        if roll < acc { return KEYS[i]; }
    }
    "abstract"
}

fn cap_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn constructed(rng: &mut Rng, b: &Bank) -> String {
    let mut s = format!("{}{}", pick(rng, b.stem), pick(rng, b.syll));
    if rng.next_u32() % 1000 < 400 { s.push_str(pick(rng, b.syll)); }
    cap_first(&s)
}

fn blocked(name: &str) -> bool {
    let low = name.to_lowercase();
    BLOCKLIST.iter().any(|b| low.contains(b))
}

pub fn brand(rng: &mut Rng, vertical: &str, traits: &[&str]) -> String {
    let b = bank(vertical);
    for _ in 0..8 {
        let pat = pick_pattern(rng, traits);
        let name = match pat {
            "amp" => {
                let a = pick(rng, b.noun);
                let mut bb = pick(rng, b.noun);
                while bb == a { bb = pick(rng, b.noun); }
                format!("{} & {}", a, bb)
            }
            "abstract" => format!("{} {}", pick(rng, b.noun), pick(rng, ABSTRACT)),
            "adjnoun"  => format!("{} {}", pick(rng, b.adj), pick(rng, b.noun)),
            "constructed" => constructed(rng, b),
            "form" => format!("{} {}", pick(rng, b.noun), pick(rng, FORM)),
            _ => format!("The {} {}", pick(rng, b.noun), pick(rng, FORM).trim_start_matches("& ")),
        };
        if !blocked(&name) { return name; }
    }
    format!("{} {}", pick(rng, b.noun), pick(rng, ABSTRACT))
}

pub fn product(rng: &mut Rng, vertical: &str) -> String {
    let b = bank(vertical);
    format!("{} {} No. {}", pick(rng, b.noun), pick(rng, b.product), 1 + rng.next_u32() % 9)
}

pub struct Identity {
    pub name: String,
    pub vertical: String,
    pub traits: Vec<String>,
    pub palette_id: u32,
    pub starting_product: String,
}

pub fn identity(rng: &mut Rng, vertical: &str) -> Identity {
    let name = brand(rng, vertical, &[]);
    let mut traits: Vec<String> = Vec::new();
    while traits.len() < 3 {
        let t = pick(rng, TRAITS).to_string();
        if !traits.contains(&t) { traits.push(t); }
    }
    let palette_id = 1 + rng.next_u32() % 8;
    let starting_product = product(rng, vertical);
    Identity { name, vertical: vertical.to_string(), traits, palette_id, starting_product }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rng::Rng;
    #[test]
    fn identity_matches_luajit() {
        let mut r = Rng::substream(7, "ident");
        let id = identity(&mut r, "cookware");
        assert_eq!(id.name, "Char Supply"); // luajit golden
    }
}
