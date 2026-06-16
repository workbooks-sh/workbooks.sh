# Workbooks Skills

Agent skills for building on [Workbooks](https://workbooks.sh) — point Claude, Cursor, Codex, or
Copilot at your project and it learns Workbooks straight from these `SKILL.md` folders.

This directory is the single shippable source of truth. `npx skills` reads it directly from GitHub;
Claude Code discovers it via per-skill symlinks in `.claude/skills/`.

## Install

**Cross-agent (primary)** — installs into `.claude/skills`, `.codex/skills`, `.cursor/skills`:

```sh
npx skills add workbooks-sh/workbooks.sh
```

Useful flags: `-g` (user-global), `-a claude-code` (pin one agent), `--skill getting-started` (one skill).

**git fallback:**

```sh
git clone --depth 1 https://github.com/workbooks-sh/workbooks.sh && cp -rf workbooks.sh/skills/* .claude/skills/
```

**curl fallback:**

```sh
curl -fsSL https://workbooks.sh/install-skills.sh | sh
```

After installing, open the **`getting-started`** skill before doing anything else.

## The skills

| Skill | What it does |
|---|---|
| `getting-started` | Onboard an agent or developer to a Workbooks repo from zero — read this FIRST. |
| `create-workbook` | Create a new single-file HTML workbook systematically (framework, WASM deps, design canon, verify). |
| `edit-workbook` | Edit an existing workbook safely via the unbundle → edit source → rebuild loop. |
| `create-toolkit` | Author a new toolkit — `manifest.org` front-door + progressively-loaded `skills/*.org` recipes. |
| `edit-toolkit` | Modify an existing toolkit while keeping the partition valid (`work toolkit verify`). |
| `create-runtime` | Stand up or extend a Workbooks runtime — staged, anti-vibe-code gate (ADVANCED). |
| `edit-runtime` | Modify the runtime/host engine — `mix compile` first gate, `mix test` suite (ADVANCED). |
| `grow-a-premium-page` | Design + build a premium page/surface to a high bar — staged design canon, motion vocabulary, archetype catalog, component library, premium-bar gate. The design twin of `create-runtime`. |
| `working-with-tasks` | Discover and work the task board — distinguishes bd/beads vs in-repo org board. |

`workbooks-system` is the umbrella/concept skill that the others reference for platform mechanism.

## How it's laid out

- Author in repo-root `skills/` — flat, public, what `npx skills` reads from GitHub.
- `.claude/skills/` holds only symlinks back into here, so there is one edit site and zero copy drift.
- Each skill is a `SKILL.md` (YAML `name` + `description` frontmatter, then a progressive-disclosure body
  pointing at `references/*.md`).
