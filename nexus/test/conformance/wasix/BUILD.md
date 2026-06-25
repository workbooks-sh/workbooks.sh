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
