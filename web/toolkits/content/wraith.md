# wraith

A static analyzer for Rust and TS/JS workspaces. `wraith` finds dead `pub` items, unused dependencies, circular imports, AI-slop signatures, near-duplicate functions, over-complex functions, and module-boundary violations — the findings an agent should surface during a clean-up pass before reviewers do.

## When to reach for it

Reach for `wraith` during clean-up passes — on a new PR or before review — to find what's dead, what's unused, and what's too complex, and to enforce which crates/modules may import which others.

## Example

```
wraith audit          # dead-code + unused-deps on git-changed files only
wraith health         # functions above cyclomatic/cognitive thresholds
wraith fix --apply    # auto-remove dead pub items + unused deps (after a dry run)
```

## What it grants

- `dead-code` (unreferenced pub items), `unused-deps` (unimported Cargo.toml deps), `health` (complexity hotspots), `slop` (AI-slop signatures), `dupes` (token-shingled clone detection), `audit` (changed-files-only), `fix` (auto-remove).
- Skill recipes for cleaning a Rust package, reducing complexity, boundary enforcement, the fix-write workflow, mechanical fn extraction, and a slop-suppression policy.

## Maturity

Stable (v0.1.0).
