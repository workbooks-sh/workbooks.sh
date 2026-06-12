# `manifest.org` — anatomy

The toolkit's **front door**: the index the runtime reads to build the
auto-injected TOOLKITS catalog, and the first thing an author/agent reads to
decide if this is the right toolkit. It indexes skills **by need**; it never
duplicates a skill's body. Source of truth: `toolkits/AUTHORING.org §"The two
artifacts"`. Exemplar: `toolkits/ffmpeg/manifest.org`.

## Frontmatter (order matters — match ffmpeg)

```org
#+TITLE: <name> toolkit
#+TOOLKIT: <slug>              # whitespace-free; == dir name == :ID:
#+VERSION: <semver of THIS wrapper, not the underlying CLI>
#+CLI_BIN: <executable on PATH, e.g. ffmpeg / git / pdftk>
#+CLI_VERSION_RANGE: <range the skills are tested against, e.g. >=6.0>
#+STATUS: stable | experimental | deprecated
#+TAGLINE: <one sentence — when to reach for this toolkit>
#+REQUIRES: <space-separated extra CLIs, e.g. "node>=20 npm">   # omit if none
```

Optional, only when they carry real information (see `brandnana`):

- `#+KIND:` — when not a plain `cli`.
- `#+ENV_KEYS:` + `#+ENV_NOTE:` — creds the CLI reads.
- `#+FLOW:` — the one-line happy-path pipeline (REQUIRED for a deep CLI — it's the
  signal that a task tier is needed and seeds the Task index).
- `#+EXEC:` / `#+TRUST:` — the invocation shape + consent posture (V3). `command`
  is the default; a 3rd-party WASM component is `#+EXEC: component` +
  `#+TRUST: third-party`.
- `#+BUILD_SRC:` — `crate:<name>` | `path:<dir>` for `wbx toolkit build` to
  auto-wrap and register the command.

## Body — one `:toolkit:` node + the skill index

```org
* <name> — <what it is>                                       :toolkit:
  :PROPERTIES:
  :ID:        <slug>          # == #+TOOLKIT
  :CLI_BIN:   <bin>           # == #+CLI_BIN
  :STATUS:    <status>        # == #+STATUS
  :SKILL_DIR: skills/
  :END:

  <2-5 sentences: what this wraps, the WHY (what an agent gets wrong from
  training priors / from skimming --help), and where NOT to use it / what
  to reach for instead.>

  Skill index (read on demand):

  | Skill        | Use when                                    |
  |--------------+---------------------------------------------|
  | =overview=   | First contact — what this toolkit covers    |
  | =<slug>=     | <the NEED that routes here, one line>       |
  | ...          | ...                                          |
```

For a deep CLI, put a **Task index ABOVE the leaf index** — one row per common
multi-verb need, keyed by the user's NOUN (`harvest <domain>`), not a verb chain.

## Rules verify enforces

- Every `skills/*.org` appears in the table **exactly once** — the table IS the
  progressive-disclosure map.
- The "Use when" column is phrased as a **need/trigger**, not a restatement of the
  skill name. "Cut a slice — first N sec" beats "trim a video". The set of
  triggers must **partition** the surface: no two skills claim the same need, no
  common need unowned.
- Group with `*— GROUP —*` rows only when the surface splits cleanly (ffmpeg:
  `*— IMAGE —*` / `*— VIDEO —*`). Don't invent groups for <6 skills.
- `:ID:` / `:CLI_BIN:` / `:STATUS:` in the drawer MUST equal the matching `#+`
  keyword (the VERIFY phase checks this exact match).
- All `#+begin_src`/`#+end_src` balanced; org parses; file < 800 LOC.
