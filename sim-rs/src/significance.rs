//! Sequential two-proportion test with Bonferroni-corrected "looks".
//! Faithful port of sim/significance.lua.
//!
//! The peeking problem is a game mechanic (the A/B race resolves on evidence,
//! never on a timer) — this is the honest-but-simple correction the spike
//! evaluates: per-look two-sided alpha = alpha_family / looks.
//!
//! Floats are used DELIBERATELY here (the one sanctioned exception to the
//! integer-only sim discipline): `f64::sqrt` maps to the same hardware sqrt as
//! luajit's `math.sqrt`, and IEEE-754 requires sqrt to be exactly rounded, so it
//! is cross-device deterministic — unlike the banned libm transcendentals
//! (docs/02-technical.md §4). All other ops here (+ - * /) are likewise exactly
//! rounded, so the whole module is bit-identical to the Lua.

/// Two-sided z critical values (tabled — no inverse-normal needed).
/// Mirrors the keyed Lua table `Z`; lookup is exact-double equality.
const Z_TABLE: [(f64, f64); 7] = [
    (0.05, 1.95996),
    (0.025, 2.24140),
    (0.02, 2.32635),
    (0.01, 2.57583),
    (0.005, 2.80703),
    (0.002, 3.09023),
    (0.001, 3.29053),
];

/// Critical z for a per-look two-sided alpha. Panics (like the Lua `assert`)
/// when the alpha is not tabled.
pub fn zcrit(alpha_per_look: f64) -> f64 {
    for &(a, z) in Z_TABLE.iter() {
        if a == alpha_per_look {
            return z;
        }
    }
    panic!("no z tabled for alpha {}", alpha_per_look);
}

/// Compare successes/trials between arms A and B (pooled two-proportion z).
/// Returns the winner (`"A"` / `"B"`, or `None` if not separated) and the z value.
///
/// Counts are integers (successes/trials); the statistics are computed in f64 to
/// mirror the Lua, where every operand is a double.
pub fn compare(
    sa: i64,
    na: i64,
    sb: i64,
    nb: i64,
    z_threshold: f64,
    n_min: i64,
) -> (Option<&'static str>, f64) {
    if na < n_min || nb < n_min {
        return (None, 0.0);
    }
    let sa = sa as f64;
    let na = na as f64;
    let sb = sb as f64;
    let nb = nb as f64;
    let pooled = (sa + sb) / (na + nb);
    if pooled <= 0.0 || pooled >= 1.0 {
        return (None, 0.0);
    }
    let se = (pooled * (1.0 - pooled) * (1.0 / na + 1.0 / nb)).sqrt();
    if se == 0.0 {
        return (None, 0.0);
    }
    let z = (sa / na - sb / nb) / se;
    if z >= z_threshold {
        return (Some("A"), z);
    }
    if z <= -z_threshold {
        return (Some("B"), z);
    }
    (None, z)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden values produced by luajit on sim/significance.lua (%.17g),
    // cross-validated byte-for-byte against this port.
    #[test]
    fn zcrit_matches_luajit() {
        assert_eq!(zcrit(0.05), 1.95996);
        assert_eq!(zcrit(0.025), 2.24140);
        assert_eq!(zcrit(0.02), 2.32635);
        assert_eq!(zcrit(0.01), 2.57583);
        assert_eq!(zcrit(0.005), 2.80703);
        assert_eq!(zcrit(0.002), 3.09023);
        assert_eq!(zcrit(0.001), 3.29053);
    }

    #[test]
    #[should_panic]
    fn zcrit_untabled_panics() {
        zcrit(0.0123);
    }

    #[test]
    fn compare_below_nmin() {
        assert_eq!(compare(5, 10, 3, 10, 1.95996, 30), (None, 0.0));
    }

    #[test]
    fn compare_winner_a() {
        let (w, z) = compare(100, 1000, 50, 1000, 1.95996, 30);
        assert_eq!(w, Some("A"));
        assert_eq!(z, 4.2447635997800894);
    }

    #[test]
    fn compare_winner_b() {
        let (w, z) = compare(50, 1000, 100, 1000, 1.95996, 30);
        assert_eq!(w, Some("B"));
        assert_eq!(z, -4.2447635997800894);
    }

    #[test]
    fn compare_no_separation() {
        let (w, z) = compare(100, 1000, 95, 1000, 2.57583, 30);
        assert_eq!(w, None);
        assert_eq!(z, 0.37690256528391242);
    }

    #[test]
    fn compare_pooled_zero() {
        assert_eq!(compare(0, 1000, 0, 1000, 1.95996, 30), (None, 0.0));
    }

    #[test]
    fn compare_pooled_one() {
        assert_eq!(compare(1000, 1000, 1000, 1000, 1.95996, 30), (None, 0.0));
    }

    #[test]
    fn compare_mid_a() {
        let (w, z) = compare(123, 4567, 89, 4567, 1.95996, 30);
        assert_eq!(w, Some("A"));
        assert_eq!(z, 2.3627097896816198);
    }

    #[test]
    fn compare_small_no_separation() {
        let (w, z) = compare(7, 50, 12, 60, 2.24140, 30);
        assert_eq!(w, None);
        assert_eq!(z, -0.82891638378843602);
    }
}
