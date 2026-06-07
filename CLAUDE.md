# CLAUDE.md — AdBuy developer notes

Mobile-first ad-account simulator game. Sim: `sim-rs/` (Rust/wasm-bindgen). UI: `app/` (vanilla JS/CSS, Vite, Capacitor 8). Before substantive work, read `README.md` and `DECISIONS.md`; the game spec lives in `docs/01-game-design.md`.

## Working rules

1. **Least code possible.** Prefer reusing and deleting over adding. **No file over 500 lines.** When a file approaches the limit, split it along a real conceptual seam — never shard mechanically to duck the rule.

2. **Folders carry context.** Deep subfolder trees are encouraged when every folder name adds meaning to what's inside it. What's not okay: conflicting folder names, or nested structures that repeat/duplicate folder structures that already exist elsewhere in the tree. The path itself should read as documentation.

3. **Beads for task management.** Use the `bd` CLI for all ongoing work: file an issue before starting, update it as you go, close it when verified. Beads is how we measure and experiment with ongoing processes — keep it current rather than batching updates at the end.

4. **Tests before features.** Write Rust unit tests in `sim-rs/src/` before implementing sim logic. Chart expected behavior first — code validates against expectation, not the reverse.

## Architecture invariants

- `sim-rs/` is the one canonical sim — Rust, compiled to WASM, JSON bridge to JS. No Lua, no Defold.
- Sim determinism: seeded RNG, integer-valued state, no float non-determinism. Sign invariants on Layer-1 truth must hold.
- Content is data, never inline code.
- Saves use `@capacitor/filesystem` — localStorage/IndexedDB are OS-evictable under WKWebView.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
