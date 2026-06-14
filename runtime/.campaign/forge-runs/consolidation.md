# Forge lane consolidation — checkpoint

LIGHT scripting+doc pass. No heavy rebuilds.

## Done
- `compilers/provision-all.sh` — idempotent loop over every `compilers/*/build.sh`, SKIP_HEAVY=1 default
  (heavy = treesitter, pcre2; duckdb has no build.sh), ONLY= subset, infra dirs excluded, summary footer.
  VERIFIED: `SKIP_HEAVY=1 ./provision-all.sh` → provisioned 21 fast lanes, skipped 2 heavy, 0 failures.
- `.campaign/LANE-COVERAGE.md` — coverage matrix (24 lanes incl duckdb), domains, naming reconciliation,
  drift section.

## Drift found
- duckdb: test exists, NO build.sh (prebuilt duckdb.wasm + ddb-link.sh/ddbq.sh). Not reproducible from
  source via the sweep. Follow-up: bounded split-TU build.sh.
- No lane missing a test. stb→stb_image_lane_test naming reconciled (not drift).

## Remaining
- Light verify: test/ compiles clean (mix compile, no run).
- Commit provision-all.sh + LANE-COVERAGE.md PATH-SPECIFICALLY (concurrent worker — no add -A/stash).
