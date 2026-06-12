# 323 Reclamation Analysis (iter 14, 2026-06-12)

Re-ran the feasibility pass against the two brokers built this campaign (host_http_get net broker;
host_exec/Stone-2 exec broker). **Honest conclusion: nothing is flippable-to-live NOW; the reclamation is
gated, not unlocked.** No items were flipped (a false "live" would be worse than an accurate "impossible").

## The numbers (keyword classification of the 323 impossible items)
- ~64 "runtime-only network" candidates (httpie, pip, Redis, netcat, dig, Vite, Supabase, …)
- ~37 "runtime-only fork-exec" candidates (bash, make, GCC, Ninja, PostgreSQL, go mod, …)
- ~222 still hard-blocked (build/codegen/thread/gpu/compounding)
- (classification is OVER-inclusive — e.g. bash/GCC also carry build blockers the keywords missed.)

## Why the candidates are NOT reclaimable by the current brokers
The brokers (host_http_get, host_exec) are **custom env.* imports for HAND-WRITTEN dock guests** (Rust/JS we
author). The 323 are **standard tools** that use **standard interfaces**:
- Network tools use **wasi-sockets / wasi-http**, never our host_http_get. Transparent reclamation needs the
  **wasi-seam generalization** (wasi-sockets/http → broker) — which is gated on the wasi-http-OUTBOUND async
  refactor (wb-0beq) AND an internet env (wb-k2im). Until then a net tool would have to be hand-rewritten as
  a dock guest calling host_http_get (per-tool build, not a "flip").
- Fork-exec tools (bash, make, GCC) **cannot compile to wasi at all** — wasi-libc has no fork/exec/process
  model, so the syscalls have no backing. host_exec doesn't help them (they can't be built); it serves NEW
  hand-written orchestrators that CHOOSE to call it.

## What the brokers DID unlock (the honest win)
- host_exec enables **compositions/orchestration of the 32 live commands** by hand-written guests (a guest
  can run jq, ripgrep, python, coreutils, … and pipe between them) — a real new capability, e2e-proven.
- host_http_get gives hand-written guests **safe, SSRF-hardened HTTP egress** — real, adversarially proven
  (deny side), reachability env-gated.

## Recommendation
- DO NOT flip the 323 — the reclamation target is ~101 candidates, **gated on wb-0beq** (wasi-seam) for
  transparent reclamation, or per-tool hand-rewrites otherwise. Revisit after wb-0beq in an internet env.
- Keep advancing capability via NEW brokered stones (durable storage next) + hand-written brokered tools,
  which is where the current brokers deliver real, validatable value.

## UPDATE (iter 32, 2026-06-12) — the gate is OPEN; 24 reclaimed
wb-0beq is FIXED (spawn_blocking) — brokered wasi-http OUTBOUND works + is SSRF-safe, PROVEN end-to-end:
a standard wasi:http fetch tool retrieved example.com's real HTML through the broker while internal targets
stayed blocked. So the earlier "gated, not unlocked" conclusion is SUPERSEDED for the http subset.
- RE-RAN the feasibility split: **24 items flipped impossible -> "reachable"** in resolved.json (http-only
  network blocker, no build/thread/gpu compounding) — package managers (Cargo, go mod, Poetry, conda, cpanm,
  pixi, pdm, OPAM, Nimble, shards, …), yt-dlp, qpdf, Tectonic, Volta, etc. Their NETWORK blocker is removed;
  each still needs a per-tool build to go fully "live" (so "reachable", not "live").
- ~37 remain wasi-SOCKETS-pending (raw TCP / db clients / listen: Redis, netcat, dig, curl/wget, etc.) —
  likely unblocked by the SAME spawn_blocking fix (the socket_addr_check SSRF filter is already wired) but
  UNVERIFIED (no easy wasi-sockets guest via componentize-js; needs a cargo-component/C wasi-sockets build).
- RECIPE (proven): build the tool as a wasi:http component -> run via Wasmex.Components with allow_http ->
  SSRF-filtered outbound for free. Permanent test: test/broker_net_e2e_test.exs.
