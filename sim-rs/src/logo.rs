//! Logo compositor. Port of sim/logo.lua (three-color recipe model).
use crate::rng::Rng;
use crate::logo_data::{CONTAINERS, FONTS, LAYOUTS, GLYPHS, COLORS, PALETTE_TRIPLETS, ICONS};

#[derive(Clone)]
pub struct Recipe {
    pub container: String,
    pub glyph: String,
    pub font: String,
    pub layout: String,
    pub c1: u32,
    pub c2: u32,
    pub c3: u32,
}

pub fn glyphs_for(vertical: &str) -> Vec<&'static str> {
    GLYPHS.iter()
        .filter(|(_, v)| *v == vertical || *v == "universal")
        .map(|(id, _)| *id)
        .collect()
}

pub fn is_icon(id: &str) -> bool { ICONS.contains(&id) }

fn pick<'a>(rng: &mut Rng, list: &[&'a str]) -> &'a str {
    list[(rng.next_u32() as usize) % list.len()]
}

/// "Surprise me" — samples a curated contrast-safe triplet. Matches the Lua
/// rng call order: trip, glyph, font, layout.
pub fn random(rng: &mut Rng, vertical: &str) -> Recipe {
    let gl = glyphs_for(vertical);
    let trip = PALETTE_TRIPLETS[(rng.next_u32() as usize) % PALETTE_TRIPLETS.len()];
    let glyph = gl[(rng.next_u32() as usize) % gl.len()].to_string();
    let font = pick(rng, FONTS).to_string();
    let layout = pick(rng, LAYOUTS).to_string();
    Recipe { container: "squircle".into(), glyph, font, layout, c1: trip[0], c2: trip[1], c3: trip[2] }
}

pub fn validate(r: &Recipe) -> Result<(), String> {
    if !CONTAINERS.contains(&r.container.as_str()) { return Err(format!("bad container: {}", r.container)); }
    if !is_icon(&r.glyph) { return Err(format!("bad glyph: {}", r.glyph)); }
    if !FONTS.contains(&r.font.as_str()) { return Err(format!("bad font: {}", r.font)); }
    if !LAYOUTS.contains(&r.layout.as_str()) { return Err(format!("bad layout: {}", r.layout)); }
    let n = COLORS.len() as u32;
    for (lbl, c) in [("c1", r.c1), ("c2", r.c2), ("c3", r.c3)] {
        if c < 1 || c > n { return Err(format!("bad {} color: {}", lbl, c)); }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rng::Rng;
    #[test]
    fn random_matches_luajit() {
        let mut r = Rng::substream(7, "logo");
        let rec = random(&mut r, "skincare");
        assert_eq!((rec.c1, rec.c2, rec.c3, rec.glyph.as_str()), (3, 17, 4, "moon"));
    }
}
