# Monorepo Build Systems + Native GitHub Integration — Research

**Scope:** Research-only. Answers two founder questions for the "collaborative
workspace = simplified monorepo, spoken in Google-Drive language" design.

1. Would a heavy build system (Bazel / Buck2 / Pants / Nx / Turborepo) help with
   monorepo management for a polyglot toolkit workspace?
2. How do we design **native GitHub repo integration** so a technical user can
   open GitHub and *see* the branching/subtrees/worktrees, while everyone else
   stays on the Drive-simple surface?

**As-of date:** 2026-06-14. Sources cited inline with URLs.

---

## TL;DR (for the founder)

- **Bazel verdict:** **AVOID adopting Bazel/Buck2/Pants as a dependency.** They
  solve a problem we have *already solved a different way* (hermetic,
  content-addressed polyglot compilation), and they violate the "stay
  Drive-simple" goal (BUILD files everywhere, JVM/Starlark, a steep curve).
  **BORROW two concepts** we don't yet have: an explicit **build graph**
  (cross-toolkit dependency edges + correct invalidation/topo order) and a
  **shared/remote content-addressed cache** (we have the content-addressing; we
  don't yet share the cache across workspaces/machines).
- **Recommended build approach:** Keep the in-wasm compiler lane as the default.
  Add a thin **workspace build graph** over it (nodes = toolkits, edges =
  declared deps, keyed by the sha256 we already compute) and promote the
  existing per-machine cache to a **shared CAS**. No new heavyweight tool, no
  BUILD-file authoring burden on users. An optional power-user "build graph"
  *view*, not an optional power-user *toolchain*.
- **GitHub integration first slice:** Ship **one-way export** (Workbooks → GitHub)
  built directly on the existing `/api/mirror` push, but make the *structure
  legible*: Drafts → branches, shared folders → subtree-style paths, Changes →
  commits with real authorship. The inbound `pull/1` + merge path already exists
  in `runtime/host/git.ex`; bidirectional is the second slice (GitHub App +
  webhooks, with Workbooks as owner-of-truth on conflict).

---

## Part 1 — Build-system landscape + verdict for us

### 1.1 The landscape (two distinct families)

There are two fundamentally different things sold as "monorepo tooling," and
conflating them is the main mistake to avoid
([Sourcegraph, 2026](https://sourcegraph.com/blog/monorepo-build-tools);
[Graphite](https://graphite.com/guides/monorepo-tooling-comparison)):

- **Polyglot heavyweights — Bazel, Buck2, Pants.** Model the repo as a
  *fine-grained dependency graph* (source-file / target level), produce
  **hermetic, reproducible** builds, and use **content-addressed storage** for
  caching that scales to terabytes
  ([Bazel remote caching](https://bazel.build/remote/caching)). They are *build
  systems* — they own compilation.
- **Lightweight task runners — Nx, Turborepo (and Lerna/Rush).** Layer caching
  and orchestration *on top of* existing tools (npm/tsc/webpack), model deps at
  the *package* level (coarser, faster to adopt), and target **JavaScript
  first** ([Sourcegraph, 2026](https://sourcegraph.com/blog/monorepo-build-tools)).
  They are *task orchestrators* — they call your existing build.

### 1.2 Per-tool, honest

| Tool | What it is | Real strengths | Real costs | Fits us? |
|---|---|---|---|---|
| **Bazel** | Google's hermetic polyglot build system (Starlark + Java built-in rules) | Fine-grained graph; hermetic; CAS remote cache + remote execution; broadest polyglot rule ecosystem and the most public migration experience ([Sourcegraph](https://sourcegraph.com/blog/monorepo-build-tools)) | Steep curve; **BUILD files everywhere**; **JVM server is resource-hungry** (scans the source tree, coordinates thousands of RPCs) ([blogsystem5](https://blogsystem5.substack.com/p/bazel-next-generation)); hermeticity is fragile in practice — embedded timestamps / mis-declared outputs cause spurious rebuilds, and adoption needs "constant tuning" of cache-hit rates ([Mindful Chase](https://www.mindfulchase.com/explore/troubleshooting-tips/build-bundling/advanced-bazel-troubleshooting-for-persistent-rebuilds-and-cache-invalidation.html); [Aspect](https://blog.aspect.build/estimating-bazel-cicd)) | **No** — duplicates our lane; violates Drive-simple |
| **Buck2** | Meta's Rust successor to Buck; **all** rules in Starlark | Lighter + faster than Bazel; Rust (no JVM); remote execution + content-addressed cache; cleanest extensibility (no built-in-Java rules) ([Buck2 why](https://buck2.build/docs/about/why/); [Tweag](https://www.tweag.io/blog/2023-07-06-buck2/)) | Thinner docs/community/examples; fewer third-party rules; still requires BUILD-file discipline + Starlark fluency ([Sourcegraph](https://sourcegraph.com/blog/monorepo-build-tools)) | **No (concept-wise the closest)** — its CAS + Starlark-only rule model is the right *idea*, wrong *weight* for us |
| **Pants** | Python-friendly build system; **infers** most deps via static analysis | Tiny BUILD files (dependency inference); good Python story | Still a full build system to learn/run; weaker for C/Rust/Zig/Go-as-wasm than its Python lane | **No** — language fit is wrong; still heavyweight |
| **Nx** | JS/TS task runner + generators; Nx Cloud remote cache | Easy remote caching; great DX for JS monorepos; package-level graph ([Sourcegraph](https://sourcegraph.com/blog/monorepo-build-tools)) | **JS-centric**; *not hermetic*; coarse graph; not a polyglot compiler | **No** — our value is polyglot wasm, not JS task running |
| **Turborepo** | Vercel JS task runner; remote cache | Minimal config; fast incremental JS builds | JS-only; not hermetic; orchestrates, doesn't compile | **No** — same reason as Nx |
| **Please** | Go-based Bazel-like (Python-ish BUILD dialect) | Lighter than Bazel; hermetic-ish | Small community; still BUILD-file authoring | **No** |

Cross-cutting: the heavyweights' *whole* value proposition — hermetic,
content-addressed, polyglot, cached — is the value proposition **we already
ship** via the wasm lane (Part 2). What they add on top is the *graph* and the
*shared cache*. See [the canonical tradeoff write-ups](https://jyn.dev/build-system-tradeoffs/)
and [Siemens' "Bazel, Buck and Friends" 2025 talk](https://opensource.siemens.com/events/2025/slides/Andreas_Herrmann__Bazel_Buck_and_Friends._How_to_Scale_your_Build.pdf).

### 1.3 Reconciliation with our reality

We already have the expensive part. From `runtime/host/package_manager.ex`:

- **Content-addressed, hermetic-ish polyglot compilation.** Each source block
  compiles to wasm via the in-sandbox toolchain (clang / mrustc / zig / go-yaegi
  / quickjs on wasmtime). The artifact is hashed (`sha256` of bytes) and stored
  at `build/cache/<sha>.wasm`. *"Same source ⇒ same hash ⇒ same path ⇒
  idempotent rebuilds"* — that is a CAS and a hermetic build action key,
  hand-rolled. The cache key already folds in `lang`, `src`, and `deps`
  (`cache_key([lang, src, Enum.join(deps, ",")])`).
- **A command/dependency registry.** `runtime/host/command_registry.ex` keys
  built commands by content hash into `build/commands/<sha>.wasm`; re-register
  with new content = new hash = atomic replace. This is most of what a build
  system's action cache + output map does.

So a Bazel-class system would **duplicate** the CAS + hermetic-action machinery
we have, **contradict** the Drive-simple north star (it forces BUILD files,
Starlark/JVM, a server process, and a real learning curve on users who are
supposed to think in folders and docs), and add operational weight (the JVM
server, cache-hit tuning) for capability we mostly own.

**What it would genuinely ADD — and we should borrow, not buy:**

1. **An explicit build graph.** Today the cache is per-artifact and the edges
   between toolkits ("toolkit B's wasm command is an input to toolkit A") are
   implicit. A real graph gives correct **topological build order**, **precise
   invalidation** (rebuild only the affected subgraph when a shared dep
   changes), and **cross-language deps across the workspace monorepo**. This is
   the single most valuable concept to lift.
2. **A shared / remote content-addressed cache.** Our CAS is local to one
   runtime's `build/` dir. Bazel/Buck2's win is a *shared* CAS so a cache entry
   built once (by any workspace member, or by CI) is reused everywhere
   ([Bazel remote caching](https://bazel.build/remote/caching)). We already emit
   the sha keys — promoting `build/cache` to a shared store (S3/registry-backed,
   keyed by the existing sha) is a small, high-leverage step.
3. **Polyglot rule extensibility as a pattern.** Buck2's "all rules in Starlark"
   is the right *shape* for letting power users teach the workspace a new
   language/toolchain without forking the host. We don't need Starlark — our
   EXEC-shape / toolkit model is already the extensibility seam; the lesson is
   to keep *rules declarative and data-driven*, not host-`.ex`-coded (consistent
   with the project's "behavior belongs in the config layer" canon).

### 1.4 Recommendation

- **AVOID:** adopting Bazel, Buck2, Pants, Nx, Turborepo, or Please as a
  dependency or a required user-facing toolchain. Every one of them is either
  the wrong weight (heavyweights → BUILD files / JVM / curve, breaks
  Drive-simple) or the wrong language focus (Nx/Turborepo → JS-only, not our
  polyglot-wasm value).
- **BORROW:** (a) the **build graph** (dep edges + topo order + precise
  invalidation), (b) the **shared content-addressed cache** (promote our local
  CAS to a shared store keyed by the sha we already compute), (c) the
  **declarative-rules** extensibility *pattern* (keep new-language support in
  the config/toolkit layer, never host code).
- **Smallest useful thing:** a **workspace build graph** layer over the existing
  lane — nodes = toolkits, edges = declared inter-toolkit deps, action key =
  the `cache_key`/sha `package_manager.ex` already produces. It turns N
  independent content-addressed builds into one correctly-ordered,
  precisely-invalidated graph **without** introducing a new build tool, a new
  config language, or a JVM. Surface it as an **optional power-user "build
  graph" *view/tier*** on top of the workspace monorepo — the default stays the
  current one-shot lane; the graph is opt-in visualization + smarter
  rebuild, not a new authoring burden.

**One-liner verdict:** *We already own Bazel's hard part (hermetic
content-addressed polyglot compilation); buying Bazel/Buck2 would duplicate it,
add a JVM/BUILD-file tax, and break Drive-simple — so borrow the build-graph and
shared-cache concepts and build a thin graph layer over our own lane.*

---

## Part 2 — What we already have, and the gap

### 2.1 The wasm compiler lane (the "build" we own)

- `runtime/host/package_manager.ex` — source block (Rust/C/Zig/Go/JS/TS/Svelte)
  → wasm, **content-addressed** into `build/cache/<sha>.wasm`; same source +
  deps ⇒ same sha ⇒ idempotent. Toolchains live under `runtime/compilers/`
  (clang, go, zig, duckdb, esbuild, ffmpeg, …).
- `runtime/host/command_registry.ex` — registers built artifacts by content hash
  into `build/commands/<sha>.wasm`; atomic replace on re-register; trust tags
  (first-party / third-party).

This is a hermetic-ish, content-addressed, polyglot build with an action cache
and output map — i.e. the substance of a build system, minus the explicit graph
and the shared cache (Part 1.3).

### 2.2 The mirror / git rail (the "GitHub push" we own)

From `runtime/host/git.ex`:

- **`mirror/3`** (line ~420) — host-agnostic `git push` of the whole tenant repo
  to *any* remote URL (GitHub/GitLab/Gitea/self-hosted/Radicle). Snapshots the
  working tree first (`ensure_commit`), with an auto-`.gitignore`
  (`Workbooks.Private`) so secrets/session data can't be swept in.
- **`forge_push/2`** + **`provision/4`** — push an existing remote, else
  *provision* a new repo via whichever forge CLI is on PATH (`gh`/`glab`/`tea`),
  then push. `detect_forge/0` prefers github > gitlab > gitea.
- **`commit_and_push/3`** — host-brokered `add -A` → commit → push for an
  agent's working dir (replaces the deleted native `run` hatch; wb-9ja).
- **`pull/1` + `reconcile/3`** (line ~253) — **inbound already exists.** Fetches
  `origin`, snapshots dirty agent work first, then `git merge` *integrates*
  (never clobbers). Splits CODE paths (`src/`, agent def, `skills/`) from DATA
  paths (`content/`, `blog/`, board) so human-edited code and agent-committed
  data replay cleanly; genuine same-file divergence returns `{:conflict, files}`
  and `merge --abort`s rather than overwriting.

### 2.3 The gap (mirror → *native* GitHub integration)

| Have | Need for native GitHub integration |
|---|---|
| One-shot `git push` of the whole repo to a remote URL | **Structure-legible** export: Drafts→branches, shared folders→subtree paths, Changes→commits with real authorship — so a technical user *sees* the workspace shape in GitHub |
| Auth via local forge CLI (`gh`/`glab`/`tea` on PATH) | A **GitHub App** install (installation tokens, fine-grained perms, dynamic rate limits) — not a CLI-on-PATH or a user PAT, for a hosted multi-tenant product |
| Inbound `pull/1` is *poll-driven* (runs at keeper tick) | **Webhook-driven** inbound (push/PR events) for near-real-time, two-way sync |
| Flat single-branch push (`push … HEAD`) | A **mapping model**: which Workbooks concept = which git ref/path, and an owner-of-truth + conflict policy |
| No shared cache / no cross-toolkit graph | (Part 1) build graph + shared CAS |

---

## Part 3 — Native GitHub integration design + the two-surface model

### 3.1 The two-surface model (same monorepo, two lenses)

One git repo per workspace is the single source of truth. Two read/write lenses
sit over it:

- **Drive-simple lens (non-technical):** folders, "Drafts," "Shared folders,"
  "Changes," "Versions." No git vocabulary. This is the default surface.
- **GitHub lens (technical/power-user):** the *same* repo, visualized natively
  in GitHub — branches, subtree paths, commit history, PRs. This is the
  visualization + management surface for power users.

They stay consistent because **both are views of one git repo**, and every
Workbooks concept has a deterministic git representation:

| Workbooks (Drive language) | Git representation | Visible in GitHub as |
|---|---|---|
| Workspace | the repo | the repository |
| Shared folder / sub-project | a **subtree path** (a top-level dir) | a directory in the tree |
| Draft | a **branch** (`draft/<name>`) | a branch |
| Change (a save) | a **commit** (real author = the editor) | a commit |
| Publish / "make live" | merge `draft/<name>` → `main` | a merged PR / fast-forward |
| Version / history | the commit log | history / blame |

Naming convergence note: a "Draft" is the *referent*; its git anchor is a
**branch**; the collision to avoid is calling it a "fork" (forks imply a
separate repo). Keep one repo, branches inside it.

**Subtree vs submodule:** use **subtree-style top-level directories**, not
submodules. Subtrees keep everything in one repo with one history — legible to a
non-technical user as "folders" and to a technical user as "a normal monorepo"
— whereas submodules add a pointer-to-another-repo concept that breaks the
single-repo mental model and is widely regarded as error-prone for exactly this
"include + locally edit" use case
([Tim Hutt, "Reasons to avoid Git submodules"](https://blog.timhutt.co.uk/against-submodules/);
[Andrey Nering, submodules vs subtrees](https://andrey.nering.dev/blog/git-submodules-vs-subtrees.html)).
The known subtree downside — fatter history when many projects share one subtree
and edit it conflictingly ([Medium overview](https://raminmammadzada.medium.com/monorepo-vs-multirepo-vs-git-submodule-vs-git-subtree-3fde1af15b76))
— is acceptable here because each workspace owns its own subtrees; we are not
vendoring a shared upstream across repos.

### 3.2 Auth: GitHub App (not OAuth, not PAT)

For a hosted, multi-tenant, bidirectional integration the clear choice is a
**GitHub App** ([Nango](https://nango.dev/blog/github-app-vs-github-oauth/);
[gocodeo](https://www.gocodeo.com/post/github-authorization-oauth-vs-github-apps);
[Knit, 2026](https://www.getknit.dev/blog/github-api-integration-guide)):

- Authenticates at the **installation** level (not tied to a single user's
  session) — so access survives a user leaving the org, unlike OAuth.
- **Fine-grained permissions** (just `contents` + `pull_requests` + webhooks),
  and **dynamic rate limits** that scale with install count (≈15k req/hr/install
  baseline) — important at multi-tenant scale.
- **Native webhooks** for inbound events without per-repo subscription plumbing.
- PATs are explicitly "scripts / one-off automation only"
  ([community discussion](https://github.com/orgs/community/discussions/109668));
  fine-grained PATs are fine for the *self-hosted single-user desktop* case but
  not for the hosted product.

Practical split: the existing `gh`/`glab`/`tea` CLI path stays for the
**desktop / self-hosted** tier (a developer's own machine); the **GitHub App**
is the hosted-product path.

### 3.3 Sync model + owner-of-truth

- **Outbound (Workbooks → GitHub):** already the strength. `mirror`/`forge_push`
  push; the new work is making the *refs/paths* match §3.1 (branch per Draft,
  subtree dir per shared folder, real commit author per Change).
- **Inbound (GitHub → Workbooks):** `pull/1` + `reconcile/3` already integrate
  via merge with the CODE/DATA split and conflict-abort. Upgrade the *trigger*
  from poll-at-keeper-tick to **webhook-driven**: GitHub App push/PR webhook →
  return `202` immediately → background worker runs `pull/1`
  ([webhook timeout guidance: respond <10s, process async](https://www.getknit.dev/blog/github-api-integration-guide)).
- **Owner-of-truth on conflict:** **Workbooks is canonical**, mirroring the
  existing `pull/1` policy — same-file divergence is **reported and rolled back
  (`merge --abort`)**, never silently overwritten. Reframe in Drive language: a
  conflicting GitHub change surfaces as *"this folder was also edited
  here — review the change"* rather than a git conflict marker. The CODE/DATA
  path split is what makes most real edits non-conflicting (humans touch code
  paths; agents touch data paths). On "who owns truth when both sides edit":
  the research consensus is that bidirectional sync needs a designated authority
  to avoid merge ambiguity ([monorepo/subtree guides](https://levelup.gitconnected.com/monorepo-vs-multi-repo-vs-git-submodule-vs-git-subtree-a-complete-guide-for-developers-961535aa6d4c));
  we pick **Workbooks-canonical** and treat GitHub edits as proposals that
  integrate cleanly or surface for review.

### 3.4 Webhook security (table-stakes)

Validate every inbound webhook's HMAC signature (`X-Hub-Signature-256`) against
the App's secret before acting; respond fast, process async
([GitHub webhook validation best practice](https://github.com/orgs/community/discussions/182735);
[REST API for GitHub App webhooks](https://docs.github.com/en/rest/apps/webhooks)).
Route the fetch through the existing `NetGuard`/broker discipline already used
in the runtime.

### 3.5 Smallest slices (sequenced)

1. **Slice 1 — Structure-legible one-way export (ship first).** Build on
   `mirror`/`forge_push`. Add the §3.1 mapping so the pushed repo *reads* as a
   monorepo: branch per Draft, subtree dir per shared folder, real commit author
   per Change. A technical user opens GitHub and immediately sees the workspace
   shape. No webhooks, no App yet — desktop/self-hosted can use the existing
   `gh` path. **This is the recommended first deliverable.**
2. **Slice 2 — GitHub App + webhook-driven inbound.** Replace CLI auth with a
   GitHub App for the hosted tier; wire push/PR webhooks → `202` → background
   `pull/1`. Now near-real-time two-way, Workbooks-canonical on conflict.
3. **Slice 3 — PR-as-Draft-review.** Map "publish a Draft" to a GitHub PR so
   technical reviewers can review/approve in GitHub while non-technical users
   click "make live" — the two surfaces reviewing the *same* change.

---

## Part 4 — Honest risks + open decisions for the founder

**Build-system risks**

- *Borrowing can drift into building Bazel-lite.* The build-graph + shared-CAS
  layer must stay thin and stay over the existing lane. If it grows a config
  language or a daemon, we've reinvented Buck2 and lost Drive-simple. Guardrail:
  the action key is the `cache_key`/sha we already compute; no new BUILD-file
  authoring is ever exposed to users.
- *Shared cache = a trust boundary.* A shared CAS shared across tenants must be
  keyed + isolated so one tenant can't poison another's cache entry. The
  existing first-party/third-party trust tags in `command_registry.ex` are the
  hook.

**GitHub-integration risks**

- *Bidirectional sync is where these products die.* Two-way + per-folder
  authority is genuinely hard; the CODE/DATA split is what makes it tractable —
  if that split blurs (e.g. agents start editing code paths), conflict rate
  spikes. Keep the slice ladder: don't ship inbound webhooks until one-way
  export is solid.
- *Translating git conflicts into Drive language is a real UX design problem*,
  not just plumbing. A "this folder also changed in GitHub — review" surface
  must exist before Slice 2, or non-technical users hit raw conflict states.
- *GitHub App review + secret management* (App registration, installation flow,
  per-install token storage, webhook secret) is operational overhead the desktop
  CLI path doesn't have.

**Open decisions (founder calls)**

1. **Default repo visibility** for exported workspaces — private (safer,
   matches current `provision` default) vs public (discovery/marketing). Likely
   private-by-default with an opt-in "make public."
2. **Does a workspace map to one GitHub repo, or can one repo back several
   workspaces?** Recommendation: **one workspace = one repo** (keeps the
   subtree/branch model clean); revisit only if users demand a true shared
   super-monorepo.
3. **How much of the build graph is power-user-visible?** A "build graph" view
   for technical users vs fully hidden behind "rebuild what changed." Recommend
   hidden-by-default, exposed as an optional power-user panel — symmetric with
   the GitHub lens.
4. **Conflict authority granularity.** Workbooks-canonical globally (simplest)
   vs per-path authority (code paths → GitHub-authoritative, data paths →
   Workbooks-authoritative). Start global; consider per-path once real
   conflicts show a pattern.
5. **Desktop vs hosted auth split.** Confirm desktop/self-hosted keeps the
   `gh`/`glab`/`tea` CLI path while hosted uses the GitHub App — two auth lanes
   to maintain.

---

## Sources (all fetched 2026-06-14)

- Sourcegraph, *Best Monorepo Build Tools for Engineering Teams (2026)* — https://sourcegraph.com/blog/monorepo-build-tools
- Graphite, *Comparing Bazel, Lerna, Nx, and Pants* — https://graphite.com/guides/monorepo-tooling-comparison
- jyn.dev, *build system tradeoffs* — https://jyn.dev/build-system-tradeoffs/
- Siemens OSS 2025, *Bazel, Buck and Friends: How to Scale your Build* (slides) — https://opensource.siemens.com/events/2025/slides/Andreas_Herrmann__Bazel_Buck_and_Friends._How_to_Scale_your_Build.pdf
- Buck2, *Why Buck2* — https://buck2.build/docs/about/why/
- Tweag, *A Tour Around Buck2* — https://www.tweag.io/blog/2023-07-06-buck2/
- Bazel docs, *Remote Caching* — https://bazel.build/remote/caching
- blogsystem5, *The next generation of Bazel builds* — https://blogsystem5.substack.com/p/bazel-next-generation
- Mindful Chase, *Advanced Bazel Troubleshooting (rebuilds + cache invalidation)* — https://www.mindfulchase.com/explore/troubleshooting-tips/build-bundling/advanced-bazel-troubleshooting-for-persistent-rebuilds-and-cache-invalidation.html
- Aspect, *Implementing Bazel in CI/CD: Challenges and Timeframes* — https://blog.aspect.build/estimating-bazel-cicd
- Knit, *GitHub API Integration Guide (2026)* — https://www.getknit.dev/blog/github-api-integration-guide
- Nango, *GitHub App vs. GitHub OAuth* — https://nango.dev/blog/github-app-vs-github-oauth/
- gocodeo, *GitHub Authorization: OAuth vs. GitHub Apps* — https://www.gocodeo.com/post/github-authorization-oauth-vs-github-apps
- GitHub community, *PAT vs OAuth vs GitHub App* — https://github.com/orgs/community/discussions/109668
- GitHub community, *Validating webhook payloads* — https://github.com/orgs/community/discussions/182735
- GitHub Docs, *REST API endpoints for GitHub App webhooks* — https://docs.github.com/en/rest/apps/webhooks
- Tim Hutt, *Reasons to avoid Git submodules* — https://blog.timhutt.co.uk/against-submodules/
- Andrey Nering, *Git: submodules vs. subtrees* — https://andrey.nering.dev/blog/git-submodules-vs-subtrees.html
- Ramin Mammadzada, *MonoRepo vs MultiRepo vs Submodule vs Subtree* — https://raminmammadzada.medium.com/monorepo-vs-multirepo-vs-git-submodule-vs-git-subtree-3fde1af15b76
- Subodh Shetty, *Monorepo vs Multi-repo vs Submodule vs Subtree* — https://levelup.gitconnected.com/monorepo-vs-multi-repo-vs-git-submodule-vs-git-subtree-a-complete-guide-for-developers-961535aa6d4c

### Internal references (this repo)
- `runtime/host/package_manager.ex` — content-addressed polyglot wasm build + cache (`build/cache/<sha>.wasm`, `cache_key/1`).
- `runtime/host/command_registry.ex` — content-hashed command store (`build/commands/<sha>.wasm`), trust tags.
- `runtime/host/git.ex` — `mirror/3`, `forge_push/2`, `provision/4`, `commit_and_push/3`, `pull/1`, `reconcile/3` (CODE/DATA split + conflict-abort).
- `runtime/compilers/` — in-sandbox toolchains (clang/go/zig/duckdb/esbuild/ffmpeg/…).
