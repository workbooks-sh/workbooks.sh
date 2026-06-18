#!/usr/bin/env python3
"""Idempotently patch the rustc-1.74 std `sys/wasi` tree for shared-memory threads.

Two edits against `rustc-1.74.0-src/library/std/src/sys/wasi/`:
  1. mod.rs — gate `thread_local_key` and `locks`/`once`/`thread_parking` on
     `cfg(target_feature="atomics")` (real futex locks + pthread-backed TLS on the
     threads path; the unsupported stubs otherwise — the stub TLS panics, recursing
     through panic_count's own thread-local → stack-exhaustion under threads).
  2. drop in `thread_local_key_threads.rs` (real TLS via inline pthread_key_* externs;
     the libc crate's wasi module doesn't expose them).

The threads std build then compiles with `--cfg target_feature=atomics`, so cfg picks
the real paths; the default (non-threads) build is byte-for-byte unaffected (the cfg
is false → the `else` arms = upstream behavior).

Idempotent: a no-op if mod.rs already references thread_local_key_threads.rs.
Usage: apply-std-threads-patch.py <path to rustc-1.74.0-src/library/std/src/sys/wasi>
"""
import sys, os, pathlib

WASI = pathlib.Path(sys.argv[1])
MOD = WASI / "mod.rs"
TLK_SRC = pathlib.Path(__file__).parent / "thread_local_key_threads.rs"

# --- 1. thread_local_key_threads.rs (real TLS) -----------------------------------
(WASI / "thread_local_key_threads.rs").write_text(TLK_SRC.read_text())

# --- 2. mod.rs gating ------------------------------------------------------------
src = MOD.read_text()
if "thread_local_key_threads.rs" in src:
    print("[std-threads-patch] mod.rs already patched — skip", file=sys.stderr)
    sys.exit(0)

# Pristine upstream 1.74 sections (flat, no cfg) → cfg_if-gated.
TLK_FROM = (
    '#[path = "../unsupported/thread_local_key.rs"]\n'
    "pub mod thread_local_key;\n"
)
TLK_TO = """cfg_if::cfg_if! {
    if #[cfg(target_feature = "atomics")] {
        // wasi-threads: real pthread-based TLS keys (libc exports pthread_key_create/
        // getspecific/setspecific/key_delete). The unsupported stub panics, which then
        // recurses through panic_count's own thread-local → stack-exhaustion.
        // (Workbooks multithreaded-Rust patch.)
        #[path = "thread_local_key_threads.rs"]
        pub mod thread_local_key;
    } else {
        #[path = "../unsupported/thread_local_key.rs"]
        pub mod thread_local_key;
    }
}
"""

LOCKS_FROM = (
    '#[path = "../unsupported/locks/mod.rs"]\n'
    "pub mod locks;\n"
    '#[path = "../unsupported/once.rs"]\n'
    "pub mod once;\n"
    '#[path = "../unsupported/thread_parking.rs"]\n'
    "pub mod thread_parking;\n"
)
LOCKS_TO = """cfg_if::cfg_if! {
    if #[cfg(target_feature = "atomics")] {
        #[path = "../unix/locks"]
        pub mod locks {
            #![allow(unsafe_op_in_unsafe_fn)]
            mod futex_condvar;
            mod futex_mutex;
            mod futex_rwlock;
            pub(crate) use futex_condvar::Condvar;
            pub(crate) use futex_mutex::Mutex;
            pub(crate) use futex_rwlock::RwLock;
        }
    } else {
        #[path = "../unsupported/locks/mod.rs"]
        pub mod locks;
        #[path = "../unsupported/once.rs"]
        pub mod once;
        #[path = "../unsupported/thread_parking.rs"]
        pub mod thread_parking;
    }
}
"""

for frm, to, label in ((TLK_FROM, TLK_TO, "thread_local_key"), (LOCKS_FROM, LOCKS_TO, "locks")):
    if frm not in src:
        print(f"[std-threads-patch] FAILED: pristine `{label}` block not found in mod.rs "
              "(upstream layout changed?)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(frm, to, 1)

MOD.write_text(src)
print("[std-threads-patch] mod.rs patched (thread_local_key + locks gated on atomics)", file=sys.stderr)
