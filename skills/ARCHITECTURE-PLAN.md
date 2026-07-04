# Skills Architecture Plan — Workbooks / Autopoet

**Thesis.** Skills are organized by *who the agent is*, not by *what topic they cover*.
There are exactly two agents we serve, and they are mirror images of each other across
one seam (the cloud + `.work` + Autopoet stack): an **external** agent (Claude Code, on a
human's machine, helping that human) and an **internal** agent (Autopoet itself, living
inside the runtime, driving its own tools). A shared **general** spine holds the one
canonical model both must agree on. This document designs the *fundamentals* each agent
needs and the folder taxonomy that carries them. It does **not** redesign the assembler —
`work skills` (`cli/src/skills.zig`) already composes `.work` doc pages into
Claude-standard `SKILL.md` bundles, and we build on it unchanged.

Grounded in the Agent Ergonomics (AX) model: 5 surfaces
(**Disclosure · Interface · Loop · Recursion · Human**) × 6 lenses
(**Coherence · Economy · Determinism · Verifiability · Prior-alignment · Safety**). See
`Apps/shinyobjectz/projects/agent-ergonomics/docs/ax-model.md`.

---

## 0. TL;DR

- **Three audiences, two experiences.** `general` (shared spine), `external` (Claude Code
  helping a human set up + operate Workbooks/Autopoet), `internal` (Autopoet driving its
  own body/tools). `general` is authored once and feeds both faces so they can never drift.
- **Format follows audience.** `internal` + `general` sources are `.work` (dogfooded — the
  agent whose skills teach `.work` carries them *as* `.work`). `external` bundles ship as
  markdown to a public `skills.sh` library. `.work` is markdown-ish, so one source page
  renders to either via the `.work`→markdown renderer.
- **Fundamentals, per experience.** External: *the-nexus-model → author-work-files →
  run-and-deploy → provision-a-cloud-nexus → deploy-and-operate-autopoet →
  secrets-and-config*. Internal: *operate-your-body → drive-the-browser →
  voice-brain-turn-taking → author-mermaid-and-presentations → use-the-nexus-tools →
  use-the-forge-failsafe → spawn-a-cloud-brain*.
- **Publishability is a build-time gate, not a convention.** A doc page is tagged
  `public` or `internal`; an `external` composition may only compose `public` pages, and
  the weave rejects a smuggle. Private stays private by construction.
- **Packaging reuses the existing seam.** Extend the *layout* (`skills/{general,external,
  internal}/*.work` app compositions), not the mechanism. Two distributions: the **internal
  package** ships into the Autopoet brain image + desktop app; the **external package** is
  the `skills.sh` markdown library installed via `npx skills add`.

---

## 1. The taxonomy

```
skills/
├── general/          # SHARED SPINE — the one model both agents obey (.work)
│   ├── the-nexus-model.work
│   ├── the-work-language.work
│   ├── the-runtime-thesis.work
│   ├── the-work-cli-map.work
│   └── secrets-and-config-discipline.work
│
├── external/         # EXPERIENCE A — Claude Code helping a HUMAN (→ markdown, skills.sh)
│   ├── set-up-workbooks.work
│   ├── author-work-files.work
│   ├── run-and-deploy-workbooks.work
│   ├── provision-a-cloud-nexus.work
│   ├── deploy-and-operate-autopoet.work
│   └── operate-the-cloud-dashboard.work
│
└── internal/         # EXPERIENCE B — AUTOPOET driving its own tools (.work, private)
    ├── operate-your-body.work
    ├── drive-the-browser.work
    ├── voice-brain-turn-taking.work      [capability: voice — desktop only]
    ├── author-mermaid-and-presentations.work
    ├── use-the-nexus-tools.work
    ├── use-the-forge-failsafe.work        [capability: forge — local only]
    └── spawn-a-cloud-brain.work
```

Each leaf is an `app :name do title … description … section … page … end` composition —
exactly the shape `skills.zig` already consumes. The **only new distinction is the audience
subfolder**, matching the assembler's own principle ("the only distinction is location").

### Why this cut, mapped to the two experiences

| Audience | Who runs it | What it optimizes | Format |
|---|---|---|---|
| **general** | both | one canonical mental model → zero drift between the two faces | `.work` |
| **external** | Claude Code / Cursor / Codex on a user's machine | help a **human** stand up + operate the stack through the public `work` CLI + APIs | markdown (public) |
| **internal** | Autopoet's `Nexus.Autopoet.Worker` brain, in-runtime | drive **privileged first-party seams** (browser, voice, Forge, nexus tools) turn-to-turn | `.work` (private) |

The external and internal sets are *not* two topic lists — they are the **same stack seen
from opposite sides**. "Deploy an Autopoet brain to the cloud" appears in both: the external
agent *helps a human do it* (`deploy-and-operate-autopoet`); the internal agent *does it to
itself* (`spawn-a-cloud-brain`). Because the shared truth (what a nexus is, what `.work` is,
the secrets rule, the runtime thesis) lives once in `general`, the two faces cite the same
source instead of re-deriving it — the anti-drift move that keeps Coherence across the seam.

---

## 2. Core fundamentals, per agent experience

This is the heart. For each experience: the concrete skills, what each covers, and why it
matters *for that agent specifically*.

### 2A. Experience A — the EXTERNAL agent (Claude Code helping a human)

This agent runs **on the user's machine, in the user's repo, with generic priors** (bash,
git, npm, markdown) and **zero priors about `.work`, the nexus, or Autopoet**. Its
cold-start problem is acute: it will mis-map everything to its bash/node instincts unless
taught first. It has **no privileged runtime access** — it acts only through the public
`work` CLI and the `/api/platform` + `/api/cloud` surfaces. It is the **human's delegate**:
setup, auth, provisioning, and billing all pass through it. That makes this whole set the
AX **Human** surface in practice.

| Skill | Covers | Why it matters for this agent |
|---|---|---|
| **set-up-workbooks** | Install the `work` CLI; `work login` (dev-only login) against `app.workbooks.sh`; `work nexus` / `work use` to pick a nexus; first `work new`. The on-ramp. | The human's setup/auth on-ramp. Without a legible first-run, the agent guesses at auth and burns turns. Escalates to the human exactly at the credential step (Human/approval). |
| **author-work-files** | `.work` grammar: prose (`[[backlinks]]`, `#tags`), typed `resource` tables (SQLite-backed), runnable `client`/`server` blocks, placement rules, **no markdown/no code fences**. | The single most-used authoring action. The agent's markdown prior is *actively wrong* here; this skill is a prior-correction, not just a reference. |
| **run-and-deploy-workbooks** | `work dev` for local parity, `work check`/`work weave`, then `work deploy local` (prod simulation) → `work deploy cloud`. Each step with a runnable verify. | The build loop. Gives the agent a per-turn execution model with exit-code/artifact confirmation instead of "did it work?" guessing (Loop/Verifiability). |
| **provision-a-cloud-nexus** | `work cloud provision \| machine \| down`; what a cloud nexus is (git-backed `.work` workspaces on a volume); the `registry.fly.io/autopoet:v1` machine model; when to scale up/down. | The "operate Workbooks" half. The irreversible/billable actions (provision, down) live here — the agent must know which verbs cost money and escalate (Safety/Human). |
| **deploy-and-operate-autopoet** | Deploy a **headless Autopoet brain** to the cloud; what a "brain" is; how to address it; LLM routing through **our Cloudflare AI Gateway** (`Nexus.Llm` auto-detects `CF_AIG_URL/TOKEN`). | The "operate Autopoet" half — the payoff. The agent is helping a human stand up an autonomous worker; it needs the brain's lifecycle + the gateway wiring or the deploy is inert. |
| **operate-the-cloud-dashboard** | `/api/platform`: org, **credits/billing**, members, tokens, and the **data explorer** (per-org `resource` tables + rows). The human's observability + admin surface at `app.workbooks.sh`. | Observability + accountability (Human surface). Points the agent at the one place the human watches, so the agent reports against it instead of narrating a black box. |

**Prerequisite from `general`:** every external skill assumes `the-nexus-model`,
`the-runtime-thesis`, and `secrets-and-config-discipline` have been read. External bundles
link them as the first references — cold-start teaches the *model* before the *actions*.

### 2B. Experience B — AUTOPOET itself (internal tools)

This agent **is** the runtime. It does not need to be taught "what a workbook is" as a
stranger — it lives in one. What it needs is **fluency with each first-party seam**, and
**capability-awareness**: the desktop body has voice and Forge; the cloud/headless body has
voice **stubbed** and no Forge. Skills are capability-gated so the same package **degrades
cleanly** across bodies. Its skills are `.work` and live in its own body — so the agent can
*read and rewrite its own skills* (self-recursion).

| Skill | Covers | Why it matters for this agent |
|---|---|---|
| **operate-your-body** | The `Nexus.Autopoet.Worker` act→observe loop; reading/writing its **notes + body as `.work`**; memory/state continuity across turns; how it stores and re-orients. | The baseline every brain needs (AX **Recursion**). This is the agent's continuity spine — without it, long trajectories accumulate drift instead of correcting it. |
| **drive-the-browser** | `Nexus.Browse`: navigate, read a page, act on the DOM, and **capture references** (screenshots) so the vision modality has capturable artifacts to reason over. | The browser is a stochastic surface; this skill makes it observable (capture-then-verify) so the agent isn't acting blind. Ties directly to the AX root-fact that visual modalities only help *with capturable references*. |
| **voice-brain-turn-taking** `[voice]` | Kokoro **TTS** + Moonshine **STT** (desktop-only): turn-taking, barge-in, when to speak vs listen, latency budget; **capability-gate** — on cloud, voice is stubbed → detect absence and degrade to text. | The "voice" + "voice-brain" pair. The determinism risk is real (audio timing); the safety risk is a headless brain trying to speak into a stub. The gate makes the mode *legible* (the agent is never wrong about whether it has a voice). |
| **author-mermaid-and-presentations** | Render **Mermaid** diagrams + assemble reveal.js **decks** (reuses the `presentation` toolkit) as first-party output the agent produces to communicate visually. | The agent's *expressive* surface — how it emits capturable visual artifacts (diagrams, slides) instead of walls of text. Composes the existing `toolkits/presentation` skill rather than re-implementing (Coherence). |
| **use-the-nexus-tools** | The internal seams the brain calls: `Nexus.Store` (VFS/SQLite), `Nexus.Effects` (`run`/`call`/`emit`/`notify`), `Nexus.Time`/`Scheduler`, `Nexus.Llm` (CF AI Gateway autodetect), and **running untrusted code in the WASM sandbox** (TinyLasers). | The agent's core action vocabulary. One coherent per-turn model of "how do I *do* a thing in here" — the difference between the brain using its own primitives and fumbling around them. |
| **use-the-forge-failsafe** `[forge]` | `Nexus.Forge` local micro-VMs (Lima/vz): when the WASM sandbox **can't** host a build, open a Forge (`mix forge run "<cmd>"`), **LOCAL-ONLY**. The escape hatch. | Must be framed as a *failsafe, not a default* — reaching for it first violates the emulation thesis. High blast-radius (a real VM), so the skill front-loads the "only when the sandbox genuinely can't" gate (Safety). |
| **spawn-a-cloud-brain** | Autopoet signs into the cloud and deploys its own **headless twin** (`registry.fly.io/autopoet:v1`); handing off work; addressing the twin. | The internal mirror of the external `deploy-and-operate-autopoet` — the agent doing to *itself* what the external agent helps a human do. Self-recursion / spawning; needs a clean handoff model or it forks its own state. |

### 2C. The `general` spine (shared fundamentals both need)

Authored once, cited by both faces. This is the single most important anti-drift asset in
the design — the moment external and internal each keep their *own* copy of "what a nexus
is", they diverge and the AX **Coherence** column collapses.

| Skill | Covers | Why both need it |
|---|---|---|
| **the-nexus-model** | Workbook / `.work` / nexus / workspace mental model; the one canonical how-it-fits. | External maps a human onto it; internal lives in it. Same truth, one source. |
| **the-work-language** | `.work` grammar fundamentals (prose + `resource` + `client`/`server`). | External authors users' workbooks; internal authors its own body/notes. Both write `.work`. |
| **the-runtime-thesis** | Untrusted code runs in WASM; bash/fs/processes/POSIX are **emulated**; native never runs. | Kills a whole class of wrong plans on both sides: the external agent that tries to "just run bash", the internal agent that tries to shell out. |
| **the-work-cli-map** | The verb surface: `weave/check/deploy/dev/secret/login/cloud/nexus/agent/forge`. | The action interface. External drives it on a laptop; internal drives it in-runtime (some verbs privileged). One legible map. |
| **secrets-and-config-discipline** | `Nexus.Secrets` / `Nexus.Config`; **NO JSON, NO env-as-config** (except machine identity); `work secret`. | Agents love to sprinkle `.env`/JSON. Both must be steered off it. Safety + accountability, single-sourced. |

---

## 3. The `.work` (internal) ↔ markdown (external) split

**One source, two renders, one gate.**

- **Source of truth is always `.work`.** `general` and `internal` pages are authored as
  `.work` doc pages; `external` compositions select from the **public** subset of those
  same pages. Nothing is authored twice.
- **The render differs by audience.** Internal + general bundles keep references as `.work`
  (the assembler already does this on purpose — "a skill that teaches `.work` is itself
  `.work`"). External bundles emit **markdown** `SKILL.md` + markdown references via the
  `.work`→markdown renderer the agent-ergonomics project already ships. `.work` is
  markdown-ish, so this is a light, lossless-enough conversion — not a rewrite.
- **What stays private vs public:**

  | | Private (internal `.work` only) | Public (external markdown, skills.sh) |
  |---|---|---|
  | **Contents** | privileged seam names (`Nexus.Browse`, `Nexus.Forge`, voice), source anchors at `file:line`, machine-identity assumptions, the brain image, self-spawn | the public `work` CLI, `.work` authoring, deploy/provision *as a user does it*, dashboard operation, the model |
  | **Audience** | Autopoet's own brain + desktop app | any external agent + the humans it serves |

- **The gate is build-time, not editorial.** Every doc page carries a `visibility` tag
  (`public` | `internal`). An `external` app composition may **only** `page` pages tagged
  `public`; the weave **rejects** a composition that references an `internal` page into a
  public bundle. So "don't leak the internal seam" is enforced by the assembler, not by
  reviewer vigilance — a private page *cannot* be smuggled into a public package. (This is
  the one small extension to the emit path: a visibility check on external compositions.
  Everything else is layout.)

---

## 4. Packaging

**Reuse the existing seam. Extend the layout, add two distributions and a capability
manifest.** `work skills` (`cli/src/skills.zig`) already: scans `<docs>/skills/*.work`
compositions, emits `<name>/SKILL.md` + `references/*.work`, and runs as a weave sidecar so
skills re-assemble on every `work weave`. We do not touch that.

**Extensions (all additive):**

1. **Three composition roots by audience** — `skills/{general,external,internal}/*.work`.
   The emitter already walks `skills/*.work`; it now walks the three subfolders and stamps
   each bundle with its audience.
2. **Capability manifest on internal skills** — extend the toolkit skills' existing header
   convention (`NETWORK: no` / `DESTRUCTIVE: no`) with a `CAPABILITY:` line
   (`voice` / `forge` / `browser` / `cloud`). At load time the brain enables only the
   skills whose capabilities are present in its body → the **same internal package degrades
   cleanly** desktop↔cloud (voice + forge present on desktop, absent on cloud) with no
   forked package.
3. **Two distributions (packages):**
   - **Internal package** = `general` + `internal` bundles, shipped as `.work` references
     **into the Autopoet brain image** (`registry.fly.io/autopoet:v1`) and the desktop app.
     The brain loads a reference on demand — dogfooding: the agent's skills are `.work` in
     its own body, so it can even rewrite them.
   - **External package** = `general` + `external` bundles, emitted as **markdown**, is the
     public **`skills.sh`** library. Distributes through the *existing* install path —
     `npx skills add workbooks-sh/workbooks.sh` — with the `skills/` symlink folder as the
     shippable surface (pointing only at the public markdown bundles).
4. **Per-toolkit skills stay co-located, get *registered* not moved.** `toolkits/*/skills/`
   already ship correct markdown (the `When to use / NETWORK / DESTRUCTIVE / Verify /
   See also` convention is good — keep it). A toolkit that a *user* uses joins the external
   package; a toolkit *Autopoet* uses (e.g. `presentation`) is **referenced** by the
   matching internal composition (`author-mermaid-and-presentations` composes `presentation`
   rather than duplicating it). One skill can thus land in both packages via composition —
   no copy.

---

## 5. AX-grounded design notes

How the structure serves the average agent, surface by surface (5 surfaces × the lenses
each most moves).

- **Disclosure.** The three-audience cut *is* progressive disclosure by *who the agent is*
  — an external agent never loads the internal seam docs, so it never pays that context
  (**Economy**). `general` is the cold-start spine: one canonical model → no contradictory
  copies to reconcile (**Coherence**), framed to correct the bash/node prior up front
  (**Prior-alignment**), teaching the runtime thesis + secrets discipline (the safe path)
  first (**Safety**). Thin `SKILL.md` + on-demand `references/*` keeps depth out of the way
  until needed. The toolkit skills' runnable **Verify** blocks let the agent confirm
  understanding *before* acting (**Verifiability**).
- **Interface.** `the-work-cli-map` gives one legible verb surface; `secrets-and-config-
  discipline` gates the irreversible inline. Capability manifests make the *mode* legible —
  the internal agent is never wrong about whether it has a voice or a Forge (**Determinism**,
  and the AX "legibility of control mode" read).
- **Loop.** `run-and-deploy-workbooks` (external) and `operate-your-body` +
  `use-the-nexus-tools` (internal) are the turn-to-turn execution models, each paired with
  an exit-code/artifact **Verify** so step success is confirmable, not vibed
  (**Verifiability**). Non-interactive flags are baked in per the project's shell canon
  (**Determinism**).
- **Recursion.** The single-sourced `general` spine means the two faces cannot drift apart
  across a long trajectory (**Coherence** held over time). `operate-your-body` is
  explicitly the memory/continuity skill. Because internal skills are `.work` in the agent's
  own body, the agent can self-review and rewrite its own skills — the compounding,
  resumable, self-improving loop the AX Recursion row rewards.
- **Human.** The entire `external` set *is* the Human surface: an external agent is the
  human's delegate for intent-intake, setup/auth, provisioning, and approval.
  `set-up-workbooks` escalates at the credential step; `provision-a-cloud-nexus` /
  `deploy-and-operate-autopoet` flag the billable/irreversible actions;
  `operate-the-cloud-dashboard` points at `app.workbooks.sh` as the human's one
  observability + audit surface (**trust/auditability, no black box, no approval spam**).

---

## 6. Migration

1. **Reclassify the current 6 as `external`.** The existing symlinks
   (`skills/* → dogfood/docs/skills/*`: `getting_started`, `authoring_work_files`,
   `deploying_workbooks`, `secrets_and_config`, `understanding_the_nexus`,
   `workbook_concepts`) are already exactly Experience A. Move their app compositions under
   `skills/external/` (or stamp `audience external`). Minimal churn — they already compose
   the right public doc pages (`introduction/*`, `language/*`, `deploy/*`, `preface/*`).
2. **Stand up `general` by re-composing existing docs.** The five spine skills are new
   *compositions*, not new prose — they select from doc pages that already exist
   (`introduction/what-is-*`, `language/*`, `deploy/secrets-and-config`, `preface/*`). Add
   the `visibility: public` tag to those pages as you go.
3. **Author `internal` fresh (private).** New `.work` doc pages for the privileged seams
   (`Nexus.Browse`, voice, `Nexus.Forge`, nexus tools, self-spawn), tagged
   `visibility: internal`, under a private docs area (the desktop app's own docs or
   `dogfood/docs/internal/`). These never symlink into the public `skills/` surface and
   never reach `skills.sh`.
4. **Per-toolkit skills: register, don't relocate.** Leave `toolkits/*/skills/*.md` where
   they are (they version with their toolkit). Route them into packages via composition:
   user-facing toolkits (`git`, `asana`, …) → external package; Autopoet-facing
   (`presentation`, `wavelet`, browser-adjacent) → referenced by the matching internal
   composition. The `presentation` toolkit is the concrete overlap and the proof the
   compose-don't-copy rule works.
5. **Fold `dogfood/skill-kb`** (`corpus`, `index.work`, `triage.work`) in as the retrieval
   index skills may *cite*, not a fourth audience. Surface its index under `general`
   discoverability if useful; it is a KB, not a package.
6. **Retire the "flat public folder" assumption.** The public `skills/` symlink surface now
   points *only* at `general` + `external` markdown bundles. Internal bundles live with the
   brain image and are never symlinked into the public surface — the publishability gate
   (§3) backstops this at build time.

---

## Appendix — end-state layout

```
skills/
├── ARCHITECTURE-PLAN.md        (this file)
├── README.md                   (updated: describes the 3-audience model + 2 packages)
├── general/*.work              → composed into BOTH packages
├── external/*.work             → external (markdown) package → skills.sh (npx skills add)
├── internal/*.work             → internal (.work) package → autopoet brain image + desktop
└── (symlinks)                  → point ONLY at general+external markdown bundles

toolkits/*/skills/*.md          → registered into packages by composition, not moved
dogfood/docs/**                 → source doc pages, each tagged visibility: public|internal
dogfood/skill-kb/               → citable KB/index, not an audience
cli/src/skills.zig              → UNCHANGED mechanism; + one visibility check on external emit
```
