# Rust crates.io — in-sandbox coverage (wb-3s8)

NOTE: Real crates.io crates that compile + run ENTIRELY in the wasm sandbox as workbook deps
(fetch from static.crates.io → mrustc.wasm → clang.wasm → link → run). Verified, not toys.

## PROVEN WORKING (23 crates as of 2026-06-07)

| crate            | ver     | class                                      |
|------------------|---------|--------------------------------------------|
| fnv              | 1.0.7   | leaf, std-feature                          |
| byteorder        | 1.4.3   | multi-file                                 |
| adler            | 1.0.2   | leaf                                       |
| base64           | 0.13.1  | multi-file                                 |
| memchr           | 2.5.0   | multi-file                                 |
| ryu              | 1.0.5   | multi-file                                 |
| bitflags         | 1.3.2   | declarative-macro                          |
| num-traits       | 0.2.15  | hyphenated name + autocfg build.rs (skip)  |
| num-integer      | 0.1.45  | TRANSITIVE (pulls num-traits) + build.rs   |
| smallvec         | 1.6.1   | leaf                                       |
| lazy_static      | 1.4.0   | declarative-macro                          |
| unicode-width    | 0.1.9   | data tables                                |
| cfg-if           | 1.0.0   | declarative-macro                          |
| void             | 1.0.2   | leaf                                       |
| static_assertions| 1.1.0   | declarative-macro                          |
| unicode-xid      | 0.2.2   | leaf                                       |
| arrayvec         | 0.5.2   | leaf (union-backed)                        |
| anyhow           | 1.0.57  | error handling (leaf)                      |
| once_cell        | 1.12.0  | lazy statics (leaf)                        |
| log              | 0.4.17  | logging facade (leaf)                      |
| bytes            | 1.1.0   | byte buffers (leaf)                        |
| regex-syntax     | 0.6.26  | regex AST parser (leaf)                    |

## WORKING CLASSES

- leaf pure-Rust crates
- multi-file crates (compiled in place; `mod` submodules resolve)
- hyphenated package names (crate_id: num-traits → num_traits)
- declarative-macro crates (macro_rules! — bitflags/lazy_static/cfg-if/static_assertions)
- autocfg build.rs crates (build.rs SKIPPED; autocfg cfgs have fallbacks, and the sandbox
  forbids the rustc-probe autocfg would run anyway)
- transitive dependency trees (sparse-index resolution + version-fallback)

## REMAINING FRONTIER (none are JIT-class walls)

- codegen build.rs (include!(env!("OUT_DIR"))) — needs compile+run build.rs + OUT_DIR preopen
- proc-macros (serde et al) — watt-style wasm proc-macro + mrustc bridge (the big unlock)
- language ceiling — newer crate versions using post-1.54 syntax (mrustc) (wb-1ec)
- runtime capabilities (tokio net/threads) — BEAM-mediated Dock imports (wb-1mv)
