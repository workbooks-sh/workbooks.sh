use rayon::prelude::*;
fn main() {
    let sum: i64 = (1..=1000i64).into_par_iter().map(|x| x).sum();
    std::process::exit(if sum == 500500 { 42 } else { 1 });
}
