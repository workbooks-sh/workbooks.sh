fn main() {
    // numerical integration of sin over [0,pi] (≈2.0) + heavy transcendental/float ops
    let n = 100_000;
    let mut sum = 0.0f64;
    let h = std::f64::consts::PI / n as f64;
    for i in 0..n {
        let x = (i as f64 + 0.5) * h;
        sum += x.sin() * h;
    }
    // also exercise sqrt, ln, exp, powf, min/max, rounding
    let mut acc = 0.0f64;
    for i in 1..1000 {
        let f = i as f64;
        acc += (f.sqrt() + f.ln() + (f * 0.001).exp() + f.powf(1.5)).fract();
        acc = acc.max(-1e9).min(1e9);
    }
    // sum should be ~2.0; assert within tolerance
    let ok = (sum - 2.0).abs() < 1e-6 && acc.is_finite();
    std::process::exit(if ok { 42 } else { 1 });
}
