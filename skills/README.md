# Workbooks Skills

Agent skills for building on [Workbooks](https://workbooks.sh) — point Claude, Cursor, Codex, or
Copilot at your project and it learns Workbooks straight from these `SKILL.md` folders.

**These skills are GENERATED from the documentation — never hand-edited.** The docs are the single
source of truth: a skill is authored once as an `app` composition in
`dogfood/docs/skills/*.work`, and `work weave` tangles it into a `SKILL.md` bundle
(frontmatter + overview + a reference index linking each composed doc page as an on-demand
`references/*.work` file). Edit the docs; re-weave; the skills update. Each generated `SKILL.md`
carries a `<!-- GENERATED -->` banner. To change a skill, change the `.work` it composes.

This directory holds **symlinks** to the generated bundles, so it stays the single shippable
surface: `npx skills` reads it from GitHub; Claude Code discovers it via per-skill symlinks in
`.claude/skills/`.

## Install

**Cross-agent (primary)** — installs into `.claude/skills`, `.codex/skills`, `.cursor/skills`:

```sh
npx skills add workbooks-sh/workbooks.sh
```

Useful flags: `-g` (user-global), `-a claude-code` (pin one agent), `--skill getting_started` (one skill).

**git fallback:**

```sh
git clone --depth 1 https://github.com/workbooks-sh/workbooks.sh && cp -rfL workbooks.sh/skills/*/ .claude/skills/
```

**curl fallback:**

```sh
curl -fsSL https://workbooks.sh/install-skills.sh | sh
```

After installing, open the **`getting_started`** skill before doing anything else.

## The skills

| Skill | What it does | Composes |
|---|---|---|
| `getting_started` | Onboard to Workbooks from zero — the model, the `.work` file, the `work` CLI. Read this FIRST. | introduction/*, tooling/* |
| `authoring_work_files` | Write correct `.work` — block grammar, kinds, declarations, placement, prose refs. Never markdown/fences. | preface/*, language/* |
| `deploying_workbooks` | Ship a workbook — run a nexus locally for parity, then deploy local or cloud with the `work` CLI. | deploy/* |
| `secrets_and_config` | Place config, secrets, and machine identity in their correct homes (`.work` deploy + `Nexus.Config` / `Nexus.Secrets`). | deploy/secrets-and-config |
| `understanding_the_nexus` | The runtime that backs `server` units, agents, data, sync — what it is, how it serves many sites, how to run one. | introduction/*, deploy/*, blog/* |
| `workbook_concepts` | The rationale: literate programming, WebAssembly as render target, docs-as-a-workbook. | preface/*, blog/* |

## How it's laid out

- **Source of truth:** `dogfood/docs/skills/*.work` — the `app` compositions.
- **Generated bundles:** `dogfood/docs/skills/<name>/{SKILL.md, references/*.work}` — emitted by
  `work weave` (a sidecar, like `llms.txt`). Never hand-edit.
- **This folder (`skills/`):** symlinks to the generated bundles — flat, public, what `npx skills` reads.
- **`.claude/skills/`:** per-skill symlinks back into here, so there is one edit site and zero copy drift.

To regenerate: `work weave dogfood/docs <out>` (or `work dev` to watch).
