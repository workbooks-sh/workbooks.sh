# WASIX §7/§8 C-conformance fixtures

These `.wasm` files are **real unix C programs compiled UNCHANGED against wasix-libc**
(`#include <sys/socket.h>`, `<poll.h>`, …) — proof that `target_family=unix` source
compiles and RUNS on the Washy runtime, its syscalls landing on our host imports
(§3 `sock_*`, §0-B `poll_oneoff`, §2 futex_*, §6 proc/signals).

## Regenerate (requires an LLVM clang with the wasm32 target + a wasix-libc sysroot)

```sh
CLANG=/opt/homebrew/opt/llvm/bin/clang          # any clang with wasm32 support
SYS=<wasix-libc sysroot>                          # e.g. wasix-org/wasix-libc build output
RD=<clang resource-dir with lib/wasm32-*/libclang_rt.builtins.a>

"$CLANG" --target=wasm32-wasip1 --sysroot="$SYS" -resource-dir="$RD" -O1 \
  unix_socket_poll.c -o unix_socket_poll.wasm
```

The committed `.wasm` lets the test run with no toolchain present (CI-friendly).
The full §7 (Rust std rebuilt with `target_family=unix` for tokio/hyper/ratatui)
needs the provisioned compiler-build machine — see bd wb-dkwy runbook.

## WASIX §8 Rust-std oracle — `rust_threads.{rs,wasm}`

A REAL Rust std binary (2 threads × 1000 `AtomicI32::fetch_add`, `join`, `exit(42)`),
compiled with the **wasix rustup toolchain** — imports the full WASIX surface (134
imports: thread_spawn_v2/thread_join/futex_*/…), IMPORTS its shared memory + function
table, and ships **passive** data segments loaded by the `start` function
`__wasm_init_memory`. This is the proof that real std-Rust threading runs on Washy.

```sh
~/.rustup/toolchains/wasix/bin/rustc --target wasm32-wasmer-wasi -O \
  rust_threads.rs -o rust_threads.wasm
```

## WASIX §8 Rust-crate oracle — `rust_rayon.{rs,wasm}`

A REAL Rust program using the **rayon** crate (work-stealing data parallelism, pulls
crossbeam-deque/epoch): `(1..=1000).into_par_iter().map(|x| x).sum() == 500500 → exit(42)`.
2596 functions, imported shared memory + function table, start fn `__wasm_init_memory`.
Beyond `rust_threads`, this exercises `thread_parallelism` (rayon pool sizing),
`thread_spawn_v2`/`thread_id`/`thread_join`/`thread_sleep`, and the asyncify
`stack_checkpoint` setjmp hook (first-time path). Proof a real concurrency crate runs.

`Cargo.toml`: `rayon = "1"`, `[profile.release] opt-level = 1`.

```sh
cd <rustwasix dir>   # Cargo.toml + rust_rayon.rs (as main_rayon.rs)
RUSTUP_TOOLCHAIN=wasix cargo +wasix build --release --target wasm32-wasmer-wasi
```

## §8 tokio (rust_tokio) — the marquee async runtime
`cargo +wasix build --release --target wasm32-wasmer-wasi` with
`tokio = { version = "1", features = ["rt", "time", "macros"] }`, a current-thread
runtime driving `yield_now().await` × 1000 + `time::sleep`. Runs with no new host
imports — the §2 thread + §0-B poll/clock surface covers it.

## §8 serde_json + regex (rust_parse) — heavy parsing/alloc stress
`cargo +wasix build --release --target wasm32-wasmer-wasi` with `serde_json = "1"` +
`regex = "1"`. Parses JSON + runs a regex with captures (5714 fns) — stresses the
asm lane's allocation/string paths interp≡asm. No new host imports.
