# DuckDB-from-source → wasm32-wasip1 : VERDICT + RECIPE

## Version
DuckDB v1.1.3 (git tag), split amalgamation.

## Split amalgamation (avoids the 25MB single-TU OOM fear)
    cd duckdb && python3 scripts/amalgamation.py --splits=64 --no-linenumbers
Produces 69 .cpp TUs (58 core duckdb-N.cpp ~150KB each, 11 third-party single-file
partitions) + duckdb.hpp (37k lines) + duckdb-internal.hpp (121k lines). EVERY TU
#includes both headers → ~158k header lines/TU preprocessed before its body.

## Required source patches (3) — all the "trivial portability" class WALLS predicted
1. SEMAPHORE (moodycamel): wasm has no platform branch → `#error Unsupported platform`.
   Inject a single-threaded Semaphore (count-only, no-op wait/signal) as an
   `#elif defined(__wasm__)||defined(__wasi__)` branch before the #error in
   duckdb-internal.hpp (moodycamel lightweightsemaphore region).
   *** Do NOT use -DDUCKDB_NO_THREADS: the amalgamation flattens BOTH the real
   moodycamel concurrentqueue.h AND duckdb's NO_THREADS stub → duplicate
   ProducerToken / template redeclaration. Build WITH real moodycamel + this shim. ***
2. HTTPLIB (cpp-httplib v0.14.3, header-only, inlined): needs full BSD sockets
   (socket/bind/connect/getsockname + sockaddr_un + getaddrinfo) which wasi-libc
   deliberately omits. EXCISE the `#ifndef CPPHTTPLIB_HTTPLIB_H ... #endif` block
   (~9376 lines) from duckdb-internal.hpp, replace with empty
   `namespace duckdb_httplib {} namespace duckdb_httplib_openssl {}`.
3. extension_install.cpp InstallFromHttpUrl(): the one caller of httplib. Replace its
   body with `throw IOException("Remote extension install disabled (no sockets)")`.
   (Remote-extension download is irrelevant to an in-memory engine.)

## Build defines / flags (PackageManager.build_c_dir extra_argv)
    -D_WASI_EMULATED_MMAN -DDUCKDB_AMALGAMATION -DNDEBUG
build_c_dir auto-adds: C++ EH (-fwasm-exceptions -wasm-use-legacy-eh=false +
libc++abi-eh.a/libunwind-eh.a), sjlj, mmap shim (--wrap=mmap), wasi emu defs, -O2.

## Driver (C API, duckdb.h)
duckdb_open(NULL)→connect→CREATE TABLE t(a INT,b VARCHAR)→INSERT→
SELECT b,COUNT(*),SUM(a) WHERE a<15 GROUP BY b. Compiles clean (8.7s, builds .o).
