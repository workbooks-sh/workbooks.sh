# Learning Center Audit — Consolidated Report

**Scope:** 21 lessons (9 units) audited per-claim against `runtime/host/*.ex`, `runtime/kernel/src/lib.rs`, `desktop/src/lib`, and the founder's spoken thesis (`paragraphs.txt`). Three structural lenses applied: curriculum-architecture, audience-fit, truth-posture.

---

## 1. Executive Summary

**Is the LMS truthful?** Largely yes, and far more than its lyrical tone suggests. ~90% of all load-bearing claims verify against real engine code, frequently to specific file:line. The scary-sounding claims — encrypt-in-the-open (sealed.ex/escrow.ex), capabilities-don't-exist-not-checked (policy.ex/imports.ex), one-reader-everywhere kernel (oql.ex + desktop oql-wasm), unfakeable ledger (ledger.ex), agent=loop+shell (agent.ex) — are all genuinely code-backed. The prose is excellent at the sentence level: analogy-first, jargon-light, conceptually honest.

**Is it well-aimed?** No. This is the central failure. The stated audience is non-technical builders who work by **talking to an AI agent**, but the curriculum is an **engine tour** ordered by how the system is built (file → format → kernel → isolation → signatures). It never teaches the audience's actual job: how to prompt, scope, delegate, review, and course-correct an agent. Their collaborator — the agent — doesn't appear until lesson 10 of 21.

**Three structural problems outrank every per-lesson nit:**
1. **Frame inversion** — "Foundations = the file" contradicts the founder's own thesis ("this is an ecosystem… the main component to STAND ON is the runtime"). The file is the core *unit*, not the *foundation*.
2. **Runtime + isolation demoted** — ~40% of the thesis is the isolation/sandbox/threat-model argument; the curriculum scatters it into sub-bullets with no unit of its own, and places the runtime *after* toolkits (backwards dependency).
3. **Missing climax + missing audience skill** — the autopoet/living-system (the thesis's emotional peak) is one stray doc-link; "how to work with your agent" is taught nowhere.

**Verdict:** Keep nearly every word of prose. Fix a small number of over-claims. **Rebuild the spine and resequence around the learner's job, not the engine's anatomy.**

---

## 2. Truth Ledger — false / aspirational claims with evidence

Out of ~150 audited claims, the overwhelming majority verify TRUE. Below are the only claims rated **false** or **aspirational**, with evidence.

### False (contradicts code/canon)
| Lesson | Claim | Evidence it's false |
|---|---|---|
| the-one-file | "All four (screen/logic/data/history) inside ONE file; send the file = send the whole thing." | Portable unit is a `.wbundle` **zip** (bundle.ex); data is a separate `vfs.sqlite` entry (vfs.ex). |
| the-one-file | "There is no server; what you see is all there is." | CLAUDE.md: Host routes live behavior to provider `runtime` over RCP/HTTP+WS. Thesis: the system IS an Elixir runtime server. |
| the-one-file | "History rides inside the file; perfect undo is part of what the file is." | git.ex: history is a server-side per-tenant git repo at the runtime data root, not in the HTML. |

### Aspirational (real intent / partial / unbenchmarked, stated as present fact)
| Lesson | Claim | Reality |
|---|---|---|
| the-one-file | "You own it fully; no company can revoke it." | True for the static view; live behavior leans on the runtime. |
| carries-its-story | "Authorship survives a machine wipe." | Only the **primary** tenant's DID is seed-persisted (git.ex:62-66); others regenerate until BYOD storage ships. |
| the-one-language | "Models arrived already knowing org; read it fluently on sight." | Thesis explicitly flags this as an **unrun benchmark**. |
| giving-it-abilities | "The floor does the vetting app-store review only pretends to do." | Unprovable comparative boast; isolation is real, the comparison is not a code fact. |
| the-one-command | "Every command tells you the next one." | Only 7 verbs carry next-hints (mode.rs:180); most return None. |
| the-one-command | "Run the identical command the agent ran, identically." | In-sandbox engine verbs bail (io.rs:163) until the Dock HTTP broker lands. |
| the-one-command | Split-pane "source on one side, living page on the other." | dev.rs serves the rendered page with a reload poll; no source pane. |
| coming-alive | Engine named "the Nexus." | Brand/lesson name; not a code identifier (referent = the real Elixir runtime). |
| safe-powers | Lowest rung = "no network, no secrets." | True of **compute**; `minimal` still grants secrets + brokered sockets (policy.ex:22-25). |
| going-live | "History feed needs no login; anyone can read it." | `/rcp/changes` not in auth.ex `@public`; returns 401 on locked/multi-tenant deploys. |
| plans-that-run | "Drag a card → the word flips to DONE (live two-way kanban)." | board.ex is one-way regen-from-bd; no org-backed drag writer exists. |
| plans-that-run | "A schedule self-runs from the bare file." | Requires a running keeper/scheduler process. |
| the-disk-grows | "Background worker materializes outside data to disk for agents." | Primitives exist (keeper.ex, host egress) but no shipped single-feature path; composed pattern. |
| a-disk-that-travels | "Single .html carries the disk." | Egress is a `.wbundle` zip (HTML + separate SQLite). |
| did-it-do-well | "Standing bench, couple of minutes, fraction of a cent." | Real but THIN/toolkit-scoped (`work toolkit eval`, toolkits.ex:307-378); no standalone evals primitive; cost/speed unbenchmarked. |
| plans-that-run (doc) | **autopoet** taught beside shipped primitives. | autopoet.ex = Phase-1 issue backlog only; collides with brand canon (never pitch self-running). **Highest-risk over-claim.** |
| the-browser | "The app is itself made of workbooks / no privileged frozen core." | Conventional Svelte app; "UI becomes a workbook" is the documented **north star**, not current state. |

**No other lesson contains a false or unsupported load-bearing claim.** `carries-its-story`, `code-in-the-document`, `safe-powers`, `compiled-plans`, `proving-origin`, `who-sees-what`, `secrets-in-the-open`, `under-the-hood`, `what-an-agent-is`, `agents-that-persist` are exceptionally code-faithful.

---

## 3. Relevance Ledger — keep / cut / reframe / merge

| # | Lesson | Unit | Verdict | Action |
|---|---|---|---|---|
| 1 | the-one-file | Found. | **Reframe** | Fix 3 false claims (no-server, history-in-file, one-HTML→bundle); reframe as core *unit* of an ecosystem. |
| 2 | carries-its-story | Found. | **Keep** | Soften machine-wipe portability + per-author attribution. |
| 3 | the-one-language | Found. | **Reframe/Move** | Soften "models already know org"; promote to its own early language unit. |
| 4 | giving-it-abilities | Making | **Keep** | Cut app-store boast; add maturity hedge (toolkits = least-mature prong); place AFTER the engine. |
| 5 | code-in-the-document | Making | **Keep** | Gate behind file/language lessons; optionally split out the upgrade-gate beat. |
| 6 | the-one-command (work) | Making | **Reframe→reference** | The agent runs work, not this user. Demote to a reference card; fix 3 embellishments. |
| 7 | coming-alive | Engine | **Keep** | Soften "thousands = resting state"; reconcile Nexus/Dock vocabulary. |
| 8 | safe-powers | Engine | **Keep** | Fix "no secrets" lowest-rung; promote isolation into a headline. |
| 9 | going-live | Engine | **Keep** | Fix public-history 401 claim; forward-point the one-word claim. |
| 10 | what-an-agent-is | Agents | **Keep + Move up** | Move to lesson 2-3; it's the spine for this audience. Note host-brokered tools. |
| 11 | agents-that-persist | Agents | **Keep** | Light reframe + trim ~15% lyrical filler; orient the non-technical reader. |
| 12 | did-it-do-well | Agents | **Keep** | Ground evals in real `work toolkit eval` surface; soften cost/speed figure. |
| 13 | plans-that-run | Automation | **Keep** | Fix two-way kanban + self-running schedule; **cut autopoet doc-link**. |
| 14 | compiled-plans | Automation | **Keep / Optional** | Strong; for this audience demote to optional back half. |
| 15 | a-disk-that-travels | The disk | **Keep / Merge** | Reconcile single-HTML; **merge unit into Trust & sharing**. |
| 16 | the-disk-grows | The disk | **Keep / Optional** | Soften pull-to-disk + "memory=files"; optional back half. |
| 17 | proving-origin | Trust | **Keep** | Best-in-set. Optional: name did:key/SHA-256 once for deep-doc bridge. |
| 18 | who-sees-what | Trust | **Keep / Trim** | Trim the seal recap (overlaps proving-origin); disambiguate "seal". |
| 19 | secrets-in-the-open | Trust | **Keep** | Note ETS key-store is non-persistent (restart = revoke). |
| 20 | the-browser | The browser | **Reframe / Demote** | Reframe "made of workbooks"→"extended via toolkits"; downgrade agent-arranges-desktop to "can"; **dissolve unit**, fold as closing lesson. |
| 21 | under-the-hood | Optional | **Keep** | Scope no-I/O to lib.rs; one line that the capability boundary lives in the seam. |

**Net:** zero topic removals. All "cuts" are structural consolidation (dissolve the two thin units, merge the two redundant "it's all the same idea" endings) plus over-claim trims.

---

## 4. Structural Verdict — architecture & order

**"Foundations" must be the ECOSYSTEM, not the file.** Lesson content is well-grounded (module→lesson mapping checks out), so this is an *architecture* problem, not fabrication. The founder's thesis is explicit: Workbooks is an ecosystem; the file is the core *unit*; the *runtime* is "the main component to stand on." Calling the file "Foundations" teaches beginners that Workbooks = a file format, then spends 8 units walking that back.

**Proposed 7-unit spine (down from 9), in the thesis's own order:**
1. **The whole thing** — the ecosystem map (artifact + runtime + Org + toolkits + living layer). Introduce the file here as the core *unit*. Fold `the-one-file` + `carries-its-story`.
2. **The one language** — Org / literate programming / tangling (`the-one-language` + `code-in-the-document`). Everything downstream is written in it.
3. **The engine & the sandbox** — the runtime as load-bearing pillar, with **isolation as its own headline** (BEAM-node isolation, Wasmtime-in-NIF, why-not-micro-VMs, the threat model, capabilities/safe-powers). **Before toolkits.**
4. **Toolkits — giving it abilities** (`giving-it-abilities` + work-as-reference) — now correctly after the engine that runs them.
5. **Agents** — unchanged content, but the agent appears far earlier overall.
6. **Automation, plans & the living system** — Automation + a **new autopoet/self-editing climax** (honestly framed, brand-canon-aligned).
7. **Trust, sharing & the disk** — merge the disk unit into trust/sharing (both = a copyable artifact staying safe/useful when handed out). Fold `the-browser` as the closing lesson; merge its "all the same idea" beat with `under-the-hood` so there is **one** climax.

**Dependency fixes:** runtime/isolation before toolkits; one ending not two; dissolve the two single-lesson units (disk, browser).

---

## 5. What's MISSING for a build-with-your-agent audience

The biggest gap: **not one lesson teaches the audience's actual job.** Add:

1. **"How to talk to your agent"** — phrasing a request, giving context/goals, describing outcomes not implementations, what a good first prompt looks like. *(The single most important missing lesson.)*
2. **"What to delegate vs. decide yourself"** — the human-in-the-loop model from the builder's seat (direction/taste/acceptance stays with you).
3. **"Reading what the agent did / catching it when it's wrong"** — builder-facing version of did-it-do-well + the-ledger, without the telemetry jargon.
4. **"Your first workbook, start to finish"** — one concrete end-to-end narrative (a marketer ships a small tool). The curriculum is entirely conceptual with zero worked example.
5. **An isolation / "why not a micro-VM" lesson** — the threat model (prompt injection, espionage, data sovereignty) is ~40% of the thesis and has no home.
6. **The autopoet / living-system climax** — code exists (autopoet.ex/dreams.ex/thoughts.ex); the thesis ends here, the curriculum doesn't teach it. Frame per brand canon ("software built in workbooks," not "sites that run themselves").
7. **Multi-tenancy & scale-by-memory-not-serverless** — a primary economic pitch (federation.ex/tenancy.ex), currently absent.
8. **Polyglot-compilers-in-WASM** — "builds never run as untrusted native code" (compilers.ex/build_broker.ex), only implied.

---

## 6. Prioritized changes for implementation

**P0 — credibility / canon risk (do first, cheap):**
1. **Demote/reframe autopoet** out of `plans-that-run` (Phase-1-only + collides with "never pitch self-running"). Move to the honest vision climax or cut.
2. **Fix `the-one-file`'s three false claims** (no-server, history-in-file, one-HTML→bundle) — they force every later unit to walk them back.
3. **Ground `did-it-do-well`** in the real `work toolkit eval` surface; soften cost/speed.
4. **Fix `going-live`** public-history claim (401 on locked/multi-tenant).
5. **Fix `plans-that-run`** two-way kanban + self-running schedule.

**P1 — architecture (the high-leverage rebuild):**
6. Rebuild the spine to **7 units, ecosystem-first**, runtime/isolation before toolkits (§4).
7. **Move `what-an-agent-is` to lesson 2-3.**
8. Add **"How to talk to your agent"** + **"Your first workbook, start to finish."**
9. Dissolve the disk + browser units; merge the two endings.

**P2 — audience reframes:**
10. Demote `work` to a reference card; move `the-one-language` format mechanics later for novices.
11. Reframe `the-browser` "made of workbooks"→"extended via toolkits"; downgrade agent-arranges-desktop to "can".
12. Add a standalone **isolation/threat-model** lesson and the **autopoet climax**.

**P3 — honesty polish (cheap, buys credibility):**
13. Per-lesson **maturity marker** (ships-today vs target-state).
14. Fix small embellishments: `safe-powers` lowest-rung "no secrets"; `the-one-command` next-hint + split-pane + in-sandbox parity; `carries-its-story` machine-wipe; `the-one-language` "models already know org"; `giving-it-abilities` app-store boast.
15. Bridge **Nexus / docking / Dock / seam** vocabulary so they don't read as four things.

**Do NOT:** gut the prose, remove topics, or treat this as a fabrication problem. It's a strong, true body of writing wearing the wrong skeleton.
