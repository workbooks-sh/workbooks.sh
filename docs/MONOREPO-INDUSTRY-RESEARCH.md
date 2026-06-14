# Monorepo / Subtree-Sync Industry Research

**As-of: 2026-06-14.** Research-only landscape for the "collaborative workspaces =
Drive-simple monorepo" design. Goal: (a) reduce tech debt by building ON a proven
OSS primitive for the subtree/sync mechanics rather than reinventing, and (b) scope
the productization / open-source exposure play.

Bottom line up front:

- **The single best "build-on" primitive is [josh](https://github.com/josh-project/josh)** —
  a git proxy that serves *virtual subtree/workspace views* of a monorepo with
  **bidirectional** push, versioned in-repo workspace definitions, and "git subtree on
  steroids" performance. It is almost a one-to-one match for our "shared folder = synced
  subtree view" mechanic. It is MIT-licensed and **already in production at rust-lang**
  via a thin `josh-sync` wrapper — which is *exactly* the product shape we'd ship.
- **jj (Jujutsu)** is the right call for the *working/undo/conflict* layer (op-log, undo,
  auto-rebase, first-class conflicts) — it powers the agent-friendly "undo anything"
  UX our `jj.ex` already gestures at. It is **orthogonal to josh** (jj = how a workspace
  is edited; josh = how folders are shared as subtree views). Lean into both, for
  different jobs.
- **The market gap is real:** every monorepo product (Nx, Turborepo, Moon, Rush, Lerna,
  Graphite, Aviator) is a *developer-tool*. None target the non-technical / Drive-simple
  user, and none combine subtree-sharing + content-addressed polyglot build under a
  Drive metaphor. That's open ground.

---

## 1. Landscape table

| Tool | What it solves | Fits our shared-folder/subtree model? | Verdict |
|---|---|---|---|
| **[josh](https://github.com/josh-project/josh)** (josh-project, MIT, Rust) | Git proxy serving *virtual subtree/workspace views* of one monorepo; reversible "algebraic" history filters; **bidirectional** (push to a view rewrites back into the mono); versioned `workspace.josh` files; fast incremental subtree-split | **Yes — direct match.** "Shared folder = a `:/path` filter view; add-to-workspace = compose paths in `workspace.josh`." Bidirectional = edits in a member workspace flow back to the source-of-truth mono. | **BUILD ON** (primary engine for the subtree mechanic) |
| **[Copybara](https://github.com/google/copybara)** (Google, Apache-2.0) | Declarative repo↔repo transform + sync; subtree-scoped; one authoritative repo; Skylark/Starlark DSL; metadata rewriting, content replacement | Partial. Great for *batch one-way mirror with transforms* (e.g. public/private split), but it's a CI-style pipeline, not a live proxy. No on-demand virtual view; sync is a scheduled job, not a "folder you open." | **BORROW** ideas (transform DSL, authoritative-repo discipline); not the live engine |
| **`git subtree`** (git core) | Vendor a repo into a subdir; split back out | Conceptually our model, but **slow** (rewrites history on every split) and no caching. josh is literally a fast cached reimplementation of this. | **AVOID** as the engine (josh supersedes it) |
| **[git-subrepo](https://github.com/ingydotnet/git-subrepo)** | Subtree-like vendoring with cleaner UX, single `.gitrepo` marker | Better ergonomics than subtree; still per-command, no live view, no shared cache across users | **AVOID** as engine; reference for the marker-file UX |
| **`git submodule`** | Pointer to an external repo at a pinned SHA | Wrong model: a *pointer*, not embedded content; notoriously bad UX, detached-HEAD traps, separate clone step. Breaks the "it's just a folder" promise. | **AVOID** |
| **sparse-checkout / partial clone** (git core) | Show/fetch only part of a big repo on demand | Complementary, not a sharing mechanic. Useful **inside** a workspace so a member only materializes the folders they joined. Pair with josh views. | **BORROW** (materialization optimization) |
| **worktrees** (git core) | Multiple working copies off one repo | Useful for *concurrent agents* each on their own change; orthogonal to sharing. jj generalizes this better (per-change working copies + auto-rebase). | **BORROW** |
| **[jj / Jujutsu](https://github.com/jj-vcs/jj)** (Google, Apache-2.0, git-compatible) | VCS with an **operation log** (every op undoable: `jj op undo`/`restore`), working-copy-as-commit, **first-class conflicts**, auto-rebase, colocates on a git repo | **Yes — for the editing/undo layer**, not the sharing layer. The "undo anything an agent did" + "concurrent agents auto-rebase" UX. Already vendored in `jj.ex`. | **BUILD ON** (working/undo layer; complements josh) |
| **[Sapling](https://github.com/facebook/sapling) + EdenFS** (Meta, MIT) | User-friendly scalable SCM; EdenFS = virtual FS materializing files on access for 10M-file repos | Sapling client is nice but Mercurial-lineage; **EdenFS (the scale magic) is not publicly supported** for external use. Overkill for our repo sizes. | **AVOID** (interesting prior art on virtual FS; not adoptable) |
| **Scalar / VFS for Git** (Microsoft, now in core git) | Make git fast on huge repos (background maintenance, partial clone, sparse) | Scale tooling for enterprise monorepos; superseded VFS-for-Git, folded into git. We don't have Windows-scale repos. | **AVOID** (not our problem size) |
| **Nx + Nx Cloud** (Nrwl, MIT + paid cloud) | JS/polyglot build orchestration, affected-graph, distributed CI, caching, generators | Build/CI tool for **developers**. Does *task graph*, not *folder sharing/sync*. Different axis entirely. | **AVOID** (not the same problem); study Nx Cloud as the SaaS-on-OSS business model |
| **Turborepo** (Vercel, MIT) | Fast task runner + remote cache for JS/TS monorepos | Same axis as Nx — build speed, not sharing. Developer tool. | **AVOID** as engine; model for "OSS core + Vercel cloud" |
| **Moon** (moonrepo, MIT) | Polyglot task runner/orchestrator, between scripts and Bazel | Developer task orchestration. Not sharing/sync. | **AVOID** |
| **Rush** (Microsoft, MIT) | Policy-heavy publishing/versioning for large JS monorepos | Enterprise JS publishing workflow. Not our user. | **AVOID** |
| **Lerna** (now Nx-backed, MIT) | Coordinated multi-package npm publish/versioning | Narrow (npm publish). Mostly a versioning tool now. | **AVOID** |
| **Graphite / Aviator** (commercial) | Stacked-PR review + merge queues on top of GitHub | Workflow products for dev teams. Adjacent (merge automation), not sharing/build. | **AVOID** |
| **Sourcegraph** (commercial + OSS-ish) | Code search/intelligence across many repos | Search, not sharing/build. | **AVOID** |
| **Gitpod** (commercial) | Cloud dev environments | Environments, not the sharing/VCS mechanic. | **AVOID** |

---

## 2. Focused verdict — josh + jj (the two real "build-on" primitives)

### josh — the subtree/workspace engine (PRIMARY)

What it is (sources below): a git HTTP/SSH **proxy** that, on the fly, transforms a
monorepo's history into virtual sub-repositories. You clone
`https://host/mono.git:/some/folder.git` and get a clean standalone repo of just that
folder, full history preserved, and **you can push back** — josh rewrites the change into
the mono. "Workspaces" are persisted, versioned filters (`workspace.josh` files committed
*in* the repo) that compose arbitrary paths into a rearranged virtual tree. It uses a
reversible filter DSL (not arbitrary scripts) and a shared incremental cache, which is why
it's "an order of magnitude faster" than `git subtree split` run repeatedly.

**Why it's the match for our mechanic:**

- *"Share a folder" = expose a `:/folder` view.* Another workspace clones/syncs that view.
- *"Add to my workspace" = vendor a toolkit/workbook in* = compose another path into this
  workspace's `workspace.josh`. Versioned in-repo, which fits the Org-substrate ethos.
- *Bidirectional* is the killer feature: a member editing a shared folder in **their**
  workspace pushes back into the source-of-truth mono, and the change propagates to every
  other workspace that views it. That is precisely "synced subtree across workspaces."
- *Maturity de-risked:* **rust-lang runs this in production** for miri, rust-analyzer,
  rustc-dev-guide, compiler-builtins, stdarch — and built a thin tool, **`josh-sync`**, to
  unify pulls/pushes. They describe josh as "git subtree on steroids." That is direct
  evidence both that the engine is production-grade *and* that the **winning product shape
  is a thin sync wrapper over josh** — i.e. exactly what Workbooks would build.

**Limits / honest caveats:**

- Stated not-yet-mature areas: merge queues with filtering, stacked-change review UI,
  Starlark-based filters. None of those block our use (we want the proxy + workspace
  filters + bidirectional sync, all of which are the mature core).
- It's a **server-side proxy** (Rust binary). It assumes a hosted source-of-truth mono.
  That fits our runtime tier (a shared server over RCP/HTTP), but the **desktop
  offline-first / oql.wasm** target can't run josh-proxy locally. So josh is a *runtime-tier*
  capability; the desktop must degrade to plain git subtree/worktree views or sync through
  the runtime. (Consistent with our architecture canon: runtime is one provider behind the
  Host; local is another.)
- Operationally it's another service to run + cache to manage. Worth it given it removes
  the hardest code we'd otherwise own.

**Recommendation:** adopt josh as the runtime-tier subtree-view engine. Wrap it the way
rust-lang did — our own thin `josh-sync`-equivalent that speaks Drive language
("share folder", "add to workspace", "sync") and stores workspace definitions in the Org
substrate. **Do not reimplement subtree-split.**

### jj (Jujutsu) — the working/undo layer (SECONDARY, orthogonal)

`runtime/host/jj.ex` already vendors jj as a *thin shell wrapper that colocates on the
existing git repo* (`jj git init --colocate`), reads the **operation log**, and exposes
status — without reimplementing anything. It's currently observe-only and no-op-safe when
`jj` is absent. The moduledoc's intent: the op-log corroborates our signed ledger
(tamper-evidence from two directions) and is the substrate for concurrent sub-agents
(each on its own jj change, jj auto-rebases the *text*, Org validations arbitrate
*meaning*).

**Why jj is worth leaning into (separately from josh):**

- **Undo UX for AI-built software:** `jj op undo` / `jj op restore <id>` makes *every*
  repo-state change reversible, and the undo is itself logged (safe to undo the undo). For
  a product where agents mutate the workspace, "undo anything the agent did, even a botched
  rebase" is a differentiating, Drive-grade safety feature git alone can't give cleanly.
- **Concurrent agents:** working-copy-as-a-commit + auto-rebase + first-class conflicts =
  multiple agents editing one workspace without the dirty-tree / merge-abort dance our
  `git.ex` currently codes around by hand (snapshot-before-merge, `merge --abort` on
  conflict). jj makes conflicts *first-class objects* instead of blocking errors.
- **git-compatible + colocate** means zero lock-in: the repo stays a normal git repo josh
  can still proxy. jj and josh **compose** (jj edits the working copy; josh shares folders
  across copies).
- Active and stable enough: v0.40 (Apr 2026), Google-developed, Apache-2.0.

**Recommendation:** keep jj, but promote it from observe-only to the **working/undo layer**:
expose `op undo`/`restore` as the workspace "time machine," and route concurrent-agent
edits through jj changes so we delete the hand-rolled snapshot/merge-abort reconciliation
in `git.ex`. This is incremental — jj.ex is already the right thin shape.

---

## 3. Productization / OSS positioning + market-gap analysis

**The gap:** the monorepo market is entirely *developer-tooling* (Nx, Turborepo, Moon,
Rush, Lerna = build/task orchestration; Graphite/Aviator = PR/merge workflow;
Sourcegraph = search). The *infrastructure* layer (josh, jj, Sapling) is OSS but raw —
you must be a VCS-literate engineer to wire it up. **Nobody packages subtree-sharing +
content-addressed polyglot build behind a non-technical, Drive-simple metaphor.** That's a
genuinely empty quadrant, and it's the one Workbooks naturally occupies.

**The differentiation (what only we have):**

1. **Drive language over monorepo mechanics** — "share a folder," "add to my workspace,"
   "sync," "undo" — instead of `git subtree split` / `josh-sync` / `jj op restore`. The
   *vocabulary* is the product.
2. **Content-addressed in-wasm polyglot build** (`package_manager.ex`: C/Rust/Zig/Go/JS
   compiled entirely in the wasmtime sandbox, sha256-addressed artifacts). No competitor
   ships "vendor a toolkit and it just builds, in any language, with no native toolchain."
   This is the moat — it's what makes a *non-technical* monorepo actually runnable.
3. **AI-built-software native** — the workspace is where agents build; josh handles sharing,
   jj handles undo/concurrency, Org substrate handles the meaning-level validation. The one
   GitHub result in this space ("Legit-Control/monorepo — git VCS for AI agents to be safe
   collaborators") confirms appetite but is a thin niche; nobody has the full Drive + build
   + sharing stack.

**The exposure / OSS play:** the precedent is exactly josh/jj/Sapling — **OSS infra, with
the product layer on top open too** (rust-lang's `josh-sync` is open; Nx's *core* is OSS,
the *cloud* is paid). Recommended shape:

- **Open-source the "monorepo manager" layer** — the thin sync/sharing/UX wrapper that
  turns josh + jj + our build lane into a Drive-simple monorepo — under **MIT or Apache-2.0**
  (matches josh/jj/Sapling/Nx; permissive maximizes adoption and avoids friction with the
  permissive deps we'd build on). This is the marketing-grade artifact: "a Drive-simple
  monorepo for AI-built software" is a clean, tweetable wedge with no direct competitor.
- **Keep the runtime/build internals + hosted sync as the commercial tier** (the Nx Cloud /
  Turborepo+Vercel model: OSS core, paid hosted cache/sync/collaboration). Our
  content-addressed build cache and multi-workspace sync server are the natural paid layer.
- **Naming/positioning caution (per our copy canon):** pitch it as "software built in
  workbooks / a Drive-simple monorepo," **not** "self-running sites" or insider VCS nouns.
  The OSS repo's README should speak Drive, not josh.

**One-liner (for the OSS repo / launch):**
*"A Drive-simple monorepo for AI-built software — share a folder, add a toolkit, undo
anything. Subtree-synced workspaces and zero-toolchain polyglot builds, built on josh + jj."*

---

## 4. Reconcile with our stack — build-on / build / borrow

Read: `runtime/host/jj.ex`, `runtime/host/git.ex`, `runtime/host/package_manager.ex`.

**What we already have (and it's well-shaped):**

- `git.ex` — thin git CLI wrapper: per-tenant repo, Ed25519/`did:key` signing identity,
  commit-as-identity, `commit_and_push`, **inbound GitOps `pull/1`** (snapshot-before-merge,
  integrate-not-overwrite, `merge --abort` on same-file conflict), a host-agnostic **mirror
  rail** (`mirror/3`, `forge_push` via gh/glab/tea), and Radicle federation
  (`publish/clone`, did:key delegates). This is our *source-of-truth + federation + identity*
  layer.
- `jj.ex` — observe-only colocated jj (op-log, status), no-op-safe. The seed of the
  working/undo layer.
- `package_manager.ex` — the content-addressed in-wasm polyglot build (the moat). Already
  sha256-addressed, idempotent, sandbox-only.

**Map:**

- **BUILD ON josh** for the cross-workspace subtree/sharing mechanic (runtime tier). New
  thin module (`Workbooks.Josh`, mirroring `jj.ex`'s shell-thin discipline) wrapping
  josh-proxy + a `workspace.josh` writer driven by the Org substrate. *Replaces* any plan to
  hand-roll subtree-split / submodule juggling. **Biggest tech-debt reduction available.**
- **BUILD ON jj** for undo + concurrent-agent editing. Promote `jj.ex` from observe-only to
  exposing `op undo`/`restore` and routing agent changes through jj. This lets us **delete**
  the hand-rolled snapshot/merge-abort reconciliation in `git.ex`'s `pull/reconcile` (jj's
  auto-rebase + first-class conflicts subsume it). Net debt *reduction*.
- **BORROW from Copybara** the transform-DSL discipline + "one authoritative repo" rule for
  any *public/private* or *cross-host* mirroring (we already have a mirror rail; Copybara's
  model informs how transforms should be declared, not a dep to adopt).
- **BORROW** sparse-checkout/partial-clone to materialize only the folders a member joined,
  and worktrees only where jj isn't colocated.
- **BUILD ourselves** (no OSS substitute exists): the **Drive-simple UX/vocabulary**, the
  **Org substrate** mapping folders↔subtree-filters↔workspaces, and the **content-addressed
  polyglot build** (already built — keep, it's the differentiator).
- **KEEP** the signing/identity (`did:key`) + Radicle federation — orthogonal to josh/jj and
  unique to us; josh proxies history, it doesn't sign or federate identity.

**Tech-debt reductions, concretely:**

1. Don't write subtree-split / shared-folder-sync code — adopt josh (rust-lang-proven).
2. Delete `git.ex` snapshot-before-merge + `merge --abort` reconciliation once jj's
   auto-rebase owns concurrent edits.
3. One thin wrapper per primitive (Josh, JJ) in the established `jj.ex` shell-thin style —
   no reimplementation, no second "runtime contract."

---

## 5. Open decisions for the founder

1. **Adopt josh as the runtime-tier subtree engine?** (Recommendation: yes — it's the
   closest-fit, MIT, production-proven primitive, and removes the hardest code we'd own.)
   Decision needed because it adds a Rust service + cache to the runtime image and is
   **server-side only** — desktop/offline must sync *through* the runtime or degrade to
   plain git views. Accept that split?
2. **Promote jj from observe-only to the working/undo layer** (exposing undo + routing agent
   edits through jj changes, then deleting the hand-rolled merge reconciliation)? Or keep jj
   as ledger-corroboration only and leave `git.ex`'s reconciliation in place?
3. **Open-source the manager layer, and under which license** (MIT vs Apache-2.0)? And which
   line is OSS vs commercial — recommendation: OSS = the sharing/sync/undo UX wrapper;
   commercial = hosted sync server + build cache (Nx-Cloud model). Confirm the cut.
4. **How much josh DSL do we expose to authors?** Hide it entirely behind Drive verbs
   (recommended for non-technical users), or expose `workspace.josh` as a power-user escape
   hatch (open-composition stance)?
5. **Desktop story for sharing:** since josh can't run in `oql.wasm`, is cross-workspace
   sharing a *runtime-required* feature (acceptable per architecture canon — sharing is a
   collaboration feature, viewing stays local), or do we need a degraded local subtree mode?

---

## Sources

- josh — repo + README: https://github.com/josh-project/josh ; docs/FAQ: https://josh-project.github.io/josh/faq.html ; DeepWiki architecture: https://deepwiki.com/josh-project/josh (all as-of 2026-06-14)
- rust-lang's use of josh + `josh-sync` ("git subtree on steroids", miri/rust-analyzer/etc.): https://blog.rust-lang.org/inside-rust/2026/06/04/how-josh-helps-rust-manage-code-across-multiple-repositories/ ; https://github.com/rust-lang/josh-sync ; https://rustc-dev-guide.rust-lang.org/external-repos.html (2026-06-04)
- josh license (MIT) / overview: https://www.libhunt.com/r/josh (as-of 2026-06-14)
- Jujutsu (jj): https://github.com/jj-vcs/jj ; git-compatibility + op-log/undo: https://docs.jj-vcs.dev/latest/git-compatibility/ ; v0.40 Apr 2026 (active) per https://github.com/jj-vcs/jj (as-of 2026-06-14)
- Copybara: https://github.com/google/copybara ; hub-and-spoke/monorepo use: https://dagster.io/blog/monorepos-the-hub-and-spoke-model-and-copybara (as-of 2026-06-14)
- git subtree vs subrepo vs submodule vs sparse-checkout/partial-clone: https://github.com/ingydotnet/git-subrepo ; https://adam-p.ca/blog/2022/02/git-submodule-subtree/ ; https://blog.timhutt.co.uk/against-submodules/ (as-of 2026-06-14)
- Sapling + EdenFS (EdenFS not publicly supported): https://github.com/facebook/sapling ; https://sapling-scm.com/docs/scale/overview/ (as-of 2026-06-14)
- Scalar / VFS for Git (superseded, folded into git): https://en.wikipedia.org/wiki/Virtual_File_System_for_Git (as-of 2026-06-14)
- Monorepo product comparison (Nx/Turborepo/Lerna/Moon/Rush, all developer-targeted): https://monorepo.tools/compare ; https://nx.dev/docs/guides/adopting-nx/nx-vs-turborepo (as-of 2026-06-14)
- "VCS for AI agents" niche prior art: https://github.com/Legit-Control/monorepo (as-of 2026-06-14)
