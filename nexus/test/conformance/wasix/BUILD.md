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

## §4/§8 termios (unix_termios) — the TUI runtime path with real compiled C
`clang --target=wasm32-wasip1 --sysroot=<wasix>` of a C program using `termios.h`
(`tcgetattr`/`tcsetattr` raw mode) + `ioctl(TIOCGWINSZ)`. wasix-libc routes these
through the §4 `tty_get`/`tty_set` host imports. Proves the terminal/TUI RUNTIME
capability (crossterm/ratatui's need) with real compiled code — those Rust crates
are blocked only on the compile-side target_family=unix, not any runtime gap.
Run with `Nexus.Washy.Tty.attach/1` (a virtual terminal, as a TUI would have).

## §3/§8 TCP loopback server (unix_tcp_server) — the runtime side of net crates
`unix_tcp_server.c`: a real wasix-libc C binary — `socket(AF_INET, SOCK_STREAM)` →
`bind(127.0.0.1:0)` → `getsockname` → `listen` → `pthread_create` (server thread
`accept`s + echoes) → main `connect` → `write("ping")` → server echoes → main `read`
→ `exit 42` iff the echo matches. Exercises the §3 BSD-socket surface
(`sock_open`/`sock_bind`/`sock_listen`/`sock_accept_v2`/`sock_addr_local`) plus the §2
pthread spawn — the server thread accepts on the listen fd `main` created (cross-thread
fd-table snapshot at spawn + gen_tcp controlling_process handoff). `write()`/`read()` on
a socket fd route through `sock_send`/`sock_recv`. Proves the runtime half of hyper/mio/
std::net. Closed two §8-oracle gaps (wb-npcv): the `__wasi_addr_port_t` tag is the
`__WASI_ADDRESS_FAMILY_*` enum (INET4=1, INET6=2 — not BSD AF_*), and cross-thread fd
sharing at spawn.

```sh
CLANG=/opt/homebrew/opt/llvm/bin/clang
SYS=/private/tmp/wasix-sysroot/wasix-sysroot/sysroot
RD=/private/tmp/wasix-rd
"$CLANG" --target=wasm32-wasip1 --sysroot="$SYS" -resource-dir="$RD" -pthread -matomics -mbulk-memory \
  -Wl,--shared-memory,--max-memory=67108864 -O1 unix_tcp_server.c -o unix_tcp_server.wasm
```

## §8 flate2 + sha2 (rust_compute) — compression + crypto bit-ops stress
`cargo +wasix build` with `flate2 = "1"` + `sha2 = "0.10"`. Zlib compress→decompress
round-trip + a SHA-256 digest (2410 fns) — stresses the asm lane's heavy
bit-manipulation/byte paths (different from parse/parallel/async). interp≡asm.

## §8 float-heavy (rust_float) — IEEE-754 asm stress
`cargo +wasix build` of a pure-std program: numerical sin-integration + sqrt/ln/exp/
powf/fract/min/max loops (2066 fns). Hammers the float asm paths (farith/fcmp/fsqrt/
rounding + {:nonfinite} Inf/NaN). interp≡asm.

## §8 num-bigint (rust_bignum) — arbitrary-precision integer stress
`cargo +wasix build` with `num-bigint = "0.4"`. 100! (158-digit multiply) + a
modular-exponentiation computed two ways that must agree (2292 fns). Hammers i64
mul/add/carry/shift/mod — self-verifying, interp≡asm.

## §8 dynamic dispatch (rust_dynamic) — call_indirect + recursion stress
`cargo +wasix build`: 1000 Box<dyn Expr> trait objects (vtable-dispatched, checked
vs inline) + a recursive vtable-dispatched tree (2056 fns). Hammers
call_indirect_dyn + deep recursion. Self-verifying, interp≡asm.
