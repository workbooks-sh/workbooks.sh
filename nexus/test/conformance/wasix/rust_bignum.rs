use num_bigint::BigUint;
use num_traits::One;
fn modpow(base: u32, mut e: u32, m: &BigUint) -> BigUint {
    let mut result = BigUint::one();
    let mut b = BigUint::from(base) % m;
    while e > 0 {
        if e & 1 == 1 { result = (&result * &b) % m; }
        b = (&b * &b) % m;
        e >>= 1;
    }
    result
}
fn main() {
    // 100! via accumulate
    let mut fact = BigUint::one();
    for i in 1u32..=100 { fact *= i; }
    let fact_ok = fact.to_string().len() == 158;  // 100! has 158 decimal digits (known)

    let m = BigUint::from(1_000_000_007u32);
    // modexp two independent ways — must AGREE (self-checks the bignum mul/mod interp≡asm)
    let fast = modpow(7, 1000, &m);
    let mut naive = BigUint::one();
    for _ in 0..1000 { naive = (&naive * BigUint::from(7u32)) % &m; }
    let modexp_ok = fast == naive && fast < m;

    std::process::exit(if fact_ok && modexp_ok { 42 } else { 1 });
}
