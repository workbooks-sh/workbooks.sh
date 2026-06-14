# In-flight background agents

Kill a runaway with `TaskStop <agentId>`. On resume, re-launch any that `failed` without a verdict.

**STATUS: no background agents in flight.** The ladder loop now runs synchronously in-conversation
(fetch source → build_c_dir / Go-wasip1 → empirical run → skip-guarded test → path-specific commit).
DuckDB landed LIVE earlier (the last heavy-build effort); no heavy builds running.

## Loop output (capabilities driven to LIVE this campaign — see FORGE-CAPABILITIES.md)
Go→wasip1: esbuild · yq · gojq · dasel · jsonnet.
C-from-source (build_c_dir): DuckDB (SQL) · Lua (scripting) · zstd (compression) · miniz (zip/gzip) ·
monocypher (crypto) · stb_image (decode) · stb_image_write (encode) · PCRE2 (regex) · gumbo (HTML) ·
libexpat (XML) · tree-sitter (code→AST, C grammar) · mini-gmp (bignum) · md4c (markdown) ·
utf8proc (Unicode) · xdiff (diff) · xxHash (hashing) · tinyexpr (math-expr).
Plus earlier: C/C++/Zig/Rust + exceptions/threads/SIMD/rayon, crates.io deps, SQLite.

## Git discipline (concurrent worker shares the repo)
Path-specific commits only (`git add <paths>` + `git commit -- <paths>` + `git push`). NEVER `git stash`
(captures their WIP) or `git add -A`.

## Productive-tail note
Clearly-distinct flagship domains are covered. Remaining = utilities (fonts/audio), more tree-sitter
grammars (Python/bash), or wiring overlapping proven leaf-libs (tinyscheme/cJSON/libyaml/tomlc99/brotli).
