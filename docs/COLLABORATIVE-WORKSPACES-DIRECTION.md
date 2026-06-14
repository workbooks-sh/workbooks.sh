# Collaborative Workspaces — consolidated direction

*Date: 2026-06-14. The single synthesis of the workspace / sharing / git-tracking research. Deep-dives: `GIT-SHARING-UX-RESEARCH.md` (sharing UX + CRDT lock), `MONOREPO-BUILD-GITHUB-RESEARCH.md` (Bazel verdict + GitHub), `MONOREPO-INDUSTRY-RESEARCH.md` (josh/jj/OSS), `AUTH-LAYERING-RESEARCH.md` (auth integrations). Research/agreement stage — nothing is built.*

## The model, in one breath
A **workspace = a simplified monorepo** (git, with virtual subtree views), spoken to non-technical users as **Google-Drive folders** and optionally shown to technical users as a **real GitHub repo**. You **share a folder** (a synced subtree), **add a toolkit/workbook to your workspace** (vendor it in), and **undo anything** (including what an agent did) — never seeing git, branches, or merges. Polyglot toolkits build through our **own content-addressed in-wasm lane** (no Bazel). CRDT lives only *inside* a workbook if its author wants it — never in the substrate.

## Build approach: build ON, don't reinvent
| Layer | Decision | Why |
|---|---|---|
| **Subtree views / sharing** | **Build on `josh`** (MIT, Rust git proxy; virtual subtree/workspace views, bidirectional; versioned `workspace.josh` filters) | Near 1:1 with "shared folder = synced subtree." rust-lang runs it in prod with a thin `josh-sync` wrapper — *exactly* our product shape. Runtime-tier (server-side); desktop syncs through the runtime (Host-provider canon). |
| **Working / undo layer** | **Promote `jj`** (already vendored in `jj.ex`, observe-only) to expose `jj op undo`/`restore` + route concurrent-agent edits through jj changes | Drive-grade "undo anything"; lets us **delete** the hand-rolled snapshot/merge-abort reconciliation in `git.ex`. Composes with josh (jj edits a copy; josh shares across copies). |
| **Polyglot build** | **Keep our in-wasm lane** (`package_manager.ex`, content-addressed `build/cache/<sha>`) | We already own Bazel's hard part (hermetic, content-addressed, polyglot). Adopting Bazel/Buck2/Pants duplicates it + adds JVM/BUILD-file tax + breaks Drive-simple. **Avoid.** Borrow only: an explicit build-graph + a shared CAS. |
| **GitHub** | **Optional** developer-friendly backup/lens, built on the existing `/api/mirror` push | Not required. Two-surface model: one repo, Drive-simple default + GitHub for power users. First slice = structure-legible one-way export (Drafts→branches, folders→subtree dirs, Changes→commits). |
| **Build-system class (Nx/Turborepo/Bazel)** | **Avoid entirely** | Different axis (task/build orchestration), all developer-tools; none occupy the non-technical/Drive-simple niche. |

## Principles (founder refinements, locked)
- **Mechanistic, system-managed git.** Agents and users are bad at git verbs, so the *platform* manages commit/pull/subtree-sync deterministically. Agents almost never issue raw git; the system commits-on-change and syncs folders automatically. Git is plumbing the user never sees. (jj's op-log + josh's filters are what make this safe.)
- **CRDT is a workbook-app feature, never the substrate.** The substrate is subtree-sync (last-writer/merge/pull). If a workbook author wants a live collaborative doc editor, *they* wire Yjs/p2p inside their workbook; our job is only to not block it. **Zero CRDT in the platform for v1.**
- **Restore = append-only.** "Restore this version" creates a *new* version identical to an old one (Google-Docs style); nothing is ever erased; safe for synced copies. Literal history erasure is a separate admin "permanently delete" (compliance), never "Restore". *(pending final founder confirm)*
- **Vendoring = pull-on-demand**; a local edit to a vendored shared folder becomes a **Draft** (never silently overwritten).
- **Permissions are multi-level** (nexus ∩ toolkit ∩ workbook), flexible. The **auth thread stays connected**: our BetterAuth is the base a tenant's *app* builds on, extending to *their* end-users — not a hard membrane. Ship **native workspace integrations for Clerk / Auth0 / WorkOS** (the integration surface from `AUTH-LAYERING-RESEARCH.md`).

## Vocabulary (lock before build)
Folder · Shared folder · Add to workspace · Update · Draft · Keep · Discard · History · Restore · Undo · Members · Roles · Share · Public link · Backup (GitHub). **Never** shown: commit, branch, merge, subtree, HEAD, rebase, josh, jj.

## OSS / productization
*"A Drive-simple monorepo for AI-built software — share a folder, add a toolkit, undo anything; subtree-synced workspaces + zero-toolchain polyglot builds, built on josh + jj."* Real market gap: every monorepo product is a developer tool; nobody packages subtree-sharing + content-addressed polyglot build behind a non-technical Drive metaphor. Our in-wasm polyglot build is the moat. **Recommended cut:** OSS the sharing/sync/undo UX wrapper (MIT/Apache-2.0, matching josh/jj); keep hosted sync + shared build cache commercial (Nx-Cloud model).

## Decisions
**Locked:** CRDT=zero (workbook-only) · Bazel=avoid, keep our lane · GitHub=optional/two-surface · mechanistic git · vendoring=pull-on-demand→Draft · auth thread connected + native Clerk/Auth0/WorkOS integrations.
**Still open (for the founder):**
1. **Restore = append-only** — final confirm (strong rec: yes).
2. **Adopt josh** as the runtime-tier subtree engine (accept server-side/desktop split — desktop syncs through the runtime)?
3. **Promote jj** to the working/undo layer and delete `git.ex`'s manual reconciliation?
4. **OSS license + the OSS-vs-commercial line** (rec: MIT/Apache wrapper, commercial hosted sync+cache).
5. **josh DSL**: hide entirely behind Drive verbs, or expose `workspace.josh` as a power-user escape hatch?

## Phased build proposal (smallest-first; nothing built yet)
1. **History + Restore** (append-only) — almost pure wiring of `/_changes` + the unwired `git.ex` diff; the headline "nothing is lost". Independent of everything.
2. **jj undo** — promote `jj.ex` to expose op-undo ("undo anything an agent did").
3. **Shared folders (josh)** — vendor josh as a runtime capability; "share a folder"/"add to workspace" as subtree views.
4. **Multi-level RBAC** (`wb-g1yo.5/.6`) — folder/toolkit/nexus permissions.
5. **Drafts** — branch + preview URL; Keep/Discard.
6. **GitHub backup/lens** (optional) + **native auth integrations** (Clerk/Auth0/WorkOS) as parallel tracks.
7. **OSS the wrapper** when the UX has settled.
