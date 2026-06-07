// WASM size guard.
// Fails if the compiled artifact grows past the ceiling — enforces opt-level=z + lto strip.
// Requires a prior wasm-pack build: `bash sim-rs/build.sh` produces app/pkg/adbuy_sim_bg.wasm.
// CI sequence: bash sim-rs/build.sh && cargo test (in sim-rs/).

const WASM: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../app/pkg/adbuy_sim_bg.wasm");
const CEILING: u64 = 512_000; // 500 KB — current ~263 KB; ~250 KB headroom for new mechanics

#[test]
fn wasm_binary_under_ceiling() {
    let meta = std::fs::metadata(WASM).unwrap_or_else(|_| {
        panic!(
            "WASM artifact not found at {WASM}\nRun `bash sim-rs/build.sh` first, then re-run tests."
        )
    });
    let size = meta.len();
    assert!(
        size < CEILING,
        "WASM size {size} bytes exceeds ceiling {CEILING} bytes (over by {})",
        size - CEILING
    );
    // Emit size as a note so CI logs show the trend even on pass.
    eprintln!("[wasm-size] {} bytes  ({:.1}% of {} ceiling)", size, size as f64 / CEILING as f64 * 100.0, CEILING);
}
