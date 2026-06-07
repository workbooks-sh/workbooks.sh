//! Deterministic PRNG: xorshift128 (Marsaglia) on u32, + FNV-1a substreams.
//! Bit-identical port of sim/rng.lua. Every Lua `u32(...)` == a Rust wrapping op.

/// FNV-1a 32-bit (matches sim/rng.lua: h = (h<<24) + h*403, all mod 2^32).
pub fn fnv1a(s: &str, seed: u32) -> u32 {
    let mut h: u32 = 2166136261u32 ^ seed;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_shl(24).wrapping_add(h.wrapping_mul(403));
    }
    h
}

#[derive(Clone)]
pub struct Rng {
    x: u32,
    y: u32,
    z: u32,
    w: u32,
}

impl Rng {
    pub fn new(seed: u32) -> Rng {
        let mut s = seed;
        let mut lcg = || {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            s
        };
        let mut r = Rng { x: lcg(), y: lcg(), z: lcg(), w: lcg() };
        // all-zero state is absorbing (compare as real sum, like the Lua)
        if (r.x as u64 + r.y as u64 + r.z as u64 + r.w as u64) == 0 {
            r.w = 88675123;
        }
        for _ in 0..8 {
            r.next_u32(); // decorrelate nearby seeds
        }
        r
    }

    /// Independent, reproducible substream from (seed, name).
    pub fn substream(seed: u32, name: &str) -> Rng {
        Rng::new(fnv1a(name, seed))
    }

    pub fn next_u32(&mut self) -> u32 {
        let t = self.x ^ self.x.wrapping_shl(11);
        self.x = self.y;
        self.y = self.z;
        self.z = self.w;
        let w = self.w;
        self.w = (w ^ (w >> 19)) ^ (t ^ (t >> 8));
        self.w
    }

    pub fn below(&mut self, n: u32) -> u32 {
        self.next_u32() % n
    }

    /// Probability as integer parts-per-million (mirrors sim/rng.lua `Rng:bernoulli`).
    /// One next_u32 draw — preserves the exact rng call order of dependents.
    pub fn bernoulli(&mut self, p_ppm: u32) -> bool {
        self.next_u32() % 1_000_000 < p_ppm
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden values produced by luajit on sim/rng.lua for substream(42,"x").
    #[test]
    fn matches_luajit_sequence() {
        let mut r = Rng::substream(42, "x");
        let got: Vec<u32> = (0..5).map(|_| r.next_u32()).collect();
        assert_eq!(
            got,
            vec![1563879887, 552360316, 1357041371, 449688130, 4032780357]
        );
    }
}
