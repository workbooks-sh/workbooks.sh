# DuckDB → LIVE — to-live attempt 2 (incremental .o cache)

## Status: ✅ DUCKDB LIVE — real SQL ran in-sandbox on wasm32-wasip1.

## VERDICT / RUN OUTPUT
    SELECT-OK rows=3 cols=3
    b | count | sum
    x | 3 | 18
    y | 2 | 19
    z | 1 | 14
    DUCKDB-LIVE-DONE         (exit 0)
CREATE TABLE + INSERT + `SELECT b,COUNT(*),SUM(a) WHERE a<15 GROUP BY b ORDER BY b`
all correct. duckdb.wasm = 34.6 MB. 70 cpp .o + 3 C-shim .o, one wasm-ld link.

## COMPLETE RECIPE (reproducible)
Builds on duckdb-recipe.md's 3 source patches (Semaphore shim, httplib excise,
InstallFromHttpUrl throw). To get to LIVE add the items below.

### Source patches (1 more, on top of recipe's 3)
- duckdb-internal.hpp ~L84689: prefix `inline ` to
  `std::string DuckDBPlatform() { // NOLINT: allow definition in header`
  (else every amalgamation TU emits it → duplicate-symbol at link).

### Compile flags (the full per-TU set, in /tmp/ddbq.sh)
  --target=wasm32-wasip1 --sysroot=/usr -O2
  -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false -mllvm -wasm-enable-sjlj
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID
  -D_WASI_EMULATED_MMAN -DL_tmpnam=260 -DDUCKDB_AMALGAMATION -DNDEBUG
  -DF_RDLCK=0 -DF_WRLCK=1 -DF_UNLCK=2 -DF_GETLK=5 -DF_SETLK=6 -DF_SETLKW=7
  '-Dsched_getcpu()=0'
  '-Dwinsize=winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }'
  '-DTIOCGWINSZ=0x5413'
NO -include (clang.wasm DirectoryEntry assert), NO /shims mount needed.

### C shims compiled + linked (3 .o)
- build/shims/mmap_shim.c  → __wrap_mmap/munmap/msync (mmap parity)
- build/shims/posix_stub.c → system/popen/tmpnam safe stubs
- wb-wasi-stubs.c          → sched_getcpu (now dead via macro) + mbedtls_hardware_poll
  (zero-filled deterministic entropy for the in-mem engine; mbedtls compiled with NO
  #error and NO -DMBEDTLS_NO_PLATFORM_ENTROPY required).

### Link (wasm-ld, mirrors compilers.ex compile_c — /tmp/ddb-link.sh)
  wasm-ld -m wasm32 -z stack-size=8388608 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
    --wrap=mmap --wrap=munmap --wrap=msync \
    /usr/lib/wasm32-wasip1/crt1-command.o  <all .o>  -lsetjmp \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid -lwasi-emulated-mman \
    -lc++ /usr/lib/wasm32-wasip1/libc++abi-eh.a /usr/lib/wasm32-wasip1/libunwind-eh.a \
    -lc /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a -o duckdb.wasm

### Run
  wasmtime -W exceptions=y -W memory64=y --dir <sysroot>::/usr --dir /tmp/duckdb-build::/work duckdb.wasm

## PRODUCTIZATION NOTE for the human
All 6 portability gaps are now -D flags or a 1-line inline patch — NO toolchain wall.
A DuckDB lane = PackageManager.build_c_dir with extra_argv = the fcntl/sched_getcpu/
winsize/TIOCGWINSZ defines (build_c_dir already supplies the rest: EH, sjlj, mmap shim,
emulated libs, the EH archives). The DuckDBPlatform `inline` + the 3 duckdb-recipe.md
source patches are applied during amalgamation prep. mbedtls entropy via the
mbedtls_hardware_poll stub. Build at low concurrency (RAM-bound, ~940MB/TU).

## ALL portability fixes found (5 total) — each a -D flag or a 1-line patch
- fcntl F_*LCK/F_*SETLK*       -> -D constants (duckdb-5)
- sched_getcpu                 -> -D'sched_getcpu()=0' (duckdb-42)
- struct winsize / TIOCGWINSZ  -> -D winsize body + -DTIOCGWINSZ (duckdb-6)
- mbedtls entropy              -> handled by wb-wasi-stubs.c (mbedtls_hardware_poll); NO #error,
                                  NO -DMBEDTLS_NO_PLATFORM_ENTROPY needed. mbedtls.o compiled clean.
- DuckDBPlatform() DUPLICATE SYMBOL at LINK: defined NON-inline in duckdb-internal.hpp
  (~line 84689, "// NOLINT: allow definition in header") -> emitted by every TU.
  FIX: 1-line header patch — prefix `inline ` to `std::string DuckDBPlatform()`.
  (Header change invalidates all amalgamation .o -> one full rebuild.)

## The two known issues — RESOLVED
1. **fcntl F_RDLCK/F_WRLCK/... undeclared** (wasi-libc omits file-locking).
   FIX: pass as plain `-D` flags (file locking is a no-op on the in-mem path):
   `-DF_RDLCK=0 -DF_WRLCK=1 -DF_UNLCK=2 -DF_GETLK=5 -DF_SETLK=6 -DF_SETLKW=7`
   Verified: duckdb-5 compiles clean with these.
2. **ldiv/lldiv/ldiv_t** — NOT a real issue in the build env. It was an ARTIFACT of
   `-I /shims` + `-include /shims/wb_duckdb_fixups.h`. clang.wasm ASSERTS
   (`DirectoryEntry.h has_value()`) on BOTH `-I <mounted /shims dir>` AND
   `-include <file>`. Dropping `-include` and using direct `-D` flags makes
   duckdb-5 compile with ZERO ldiv error. So: do NOT use a forced-include shim
   header with this clang.wasm — use `-D` defines instead.

## KEY FINDING (clang.wasm limitation)
`-include <path>` (forced include) and `-I <separately-mounted dir>` trigger
`Assertion failed: has_value() (DirectoryEntry.h:136)` → wasm trap. The fcntl
fix therefore ships as `-D` flags, NOT a `-include` header. `/shims` mount is
NOT needed (httplib was excised, so the socket headers are never included).

## Per-TU compile (proven)
See /tmp/ddb-build.sh CFLAGS. Incremental: skips any .o newer than its .cpp.

## C shims (compiled separately, included in link)
- wb-mmap_shim.c (host build/shims/mmap_shim.c) → __wrap_mmap/munmap/msync
- wb-posix_stub.c (host build/shims/posix_stub.c) → system/popen/tmpnam stubs
- wb-wasi-stubs.c → sched_getcpu + mbedtls_hardware_poll (entropy)
All 3 → .o, OK.

## Link: /tmp/ddb-link.sh (mirrors compilers.ex compile_c wasm-ld)
crt1-command.o + all .o + --wrap=mmap/munmap/msync + -lsetjmp + emulated libs +
-lc++ libc++abi-eh.a libunwind-eh.a + -lc + libclang_rt.builtins.a.

## INCIDENT: fan-out runaway (killed per CRASH-PROTOCOL)
An external process kept re-launching/editing /tmp/ddb-build.sh (the `-include` +
`-DMBEDTLS_NO_PLATFORM_ENTROPY` lines reappeared after I removed them), and at one
point 50 concurrent clang.wasm processes were spawned (~machine-threatening).
Killed all. LESSON: do NOT edit/re-run /tmp/ddb-build.sh. Use the uniquely-named
one-shot /tmp/ddbq.sh instead (single sequential process, freshness-checks vs both
the .cpp AND duckdb-internal.hpp so the inline patch invalidates stale .o). The .o
cache survived — durable checkpoint.

## CANONICAL build script = /tmp/ddbq.sh (CFLAGS embedded there)
No /shims mount, no -include (clang.wasm DirectoryEntry assert), winsize via macro.

## Resume / next command
- Build progress = .o cache in /tmp/duckdb-build/. Resume: `zsh /tmp/ddbq.sh` (sequential, safe).
- When all 70 cpp .o + 3 wb-*.o exist: `zsh /tmp/ddb-link.sh` → duckdb.wasm
- Then run: `wasmtime -W exceptions=y -W memory64=y --dir /tmp/duckdb-build::/work /tmp/duckdb-build/duckdb.wasm`
  OR PackageManager.run(duckdb.wasm,...). Expect SELECT-OK rows=3 + grouped output + DUCKDB-LIVE-DONE.
