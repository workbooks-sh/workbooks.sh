# Git / Sharing / Collaboration UX — Research & Design (v2)

*Date: 2026-06-14. **v2 supersedes v1.** RESEARCH + DESIGN ONLY — no app code, no app-file changes. The founder reframed the model: **sharing ≈ Google-Drive shared folders, functionally a simplified monorepo (git subtrees), spoken in Drive vocabulary — users never see git nouns.** This revision captures that faithfully, locks down where CRDT is genuinely required vs where git-subtree-sync suffices, and reconciles agent-git-behavior / CI-CD / workflows / permissions as ONE authored system. Companion to `docs/TEAM-SHARING-DESIGN.md` (workspace = WorkOS org, roles, seats), `docs/AUTH-LAYERING-RESEARCH.md`, `docs/HOSTED-NEXUS-ECONOMICS.md`, and the learn surfaces (`web/learn/{git,gitops,sharing,who-sees-what,changelogs}.html`).*

> Grounded strictly in the system maps + the cited code. New ideas are tagged **[NEW]** with the primitive they build on. Don't invent capabilities.

---

## 0. The one-paragraph thesis (revised)

The running project **is** a git repo (not "integrates with git"). Each tenant gets a repo at `$WB_DATA/<tenant>` (`git.ex:16,28-42`); a workbook is one `.org` file; **every deploy is a commit** that atomically commits-publishes-pushes (`git.ex:160-169,186-229`). Both humans **and agents** write commits. **v2's reframe:** collaboration is not "give someone a branch" — it's **shared folders, à la Google Drive**, which under the hood is a **simplified monorepo**: a vendored artifact is pulled into another workspace as a *subtree that receives updates* (`Library.pack`/`install`, `git.ex:pull`). Users speak Drive ("is this folder shared?", "add to my workspace", "see version history"); we translate to git/runtime reality behind the membrane. The job is **not** to build version control — it's to put a Drive-grade face on the one we have, and to be **precise** about the one place that face is a lie: there is **no real-time co-editing** today (no CRDT, greenfield), so "shared folder" = subtree-sync, and only a deliberately tiny set of surfaces ever earns CRDT.

---

## 1. The mental model — collaborative workspaces = a Google-Drive-simplified monorepo

A "shared folder" in Workbooks is a **subtree of a monorepo** that two workspaces both track. Sharing a *toolkit* or *workbook* **vendors** it — pulls a copy into the recipient's workspace that keeps receiving updates from the source (`Library.pack → store → fetch → install`, `git.ex:pull` merge-snapshot). Sharing a *deployment* is just handing over a **URL** of a deployed app (`PublicWeb`, `domains.ex`). Sharing an *artifact* = **vendoring it in**. The user sees only Drive nouns; we own the git/runtime translation.

| Drive / user noun (what they see) | Git / runtime reality (what we do) | Primitive (status) |
|---|---|---|
| **Shared folder** ("this folder is shared with Acme") | A monorepo **subtree** both workspaces track — a `workspace.org` member referenced by `:PATH:`/`:DID:` with a `:SCOPE:` | `workspace.ex` MEMBERS/SCOPE (parsed, **not enforced**) + `Library` access-graph |
| **Add to my workspace** ("vendor it in") | **Vendor** the artifact: pack → store → fetch → install into the recipient repo as a tracked subtree | `Library.pack/store/fetch/install` ✅ (`wb-pkh.3` done); toolkit-import lane ✅ (`wb-4lx9/i6b4/b5p6/fc2l` done) |
| **Update** ("there's a newer version — pull it") | Re-fetch the vendored subtree + **merge** into the live repo, no-clobber (CODE/DATA lanes) | `git.ex:pull/1` (`{:ok,:uptodate}` / `{:applied}` / `{:conflict,files}`) ✅ |
| **Folder permissions** ("who can view / edit this folder") | **Multi-level RBAC**: nexus-scope ∩ toolkit-scope ∩ workbook-scope, member SCOPE capped by grant | `Library.access/3` (owner-or-none today) + `Tenant.visible?` binary gate; RBAC = **`wb-g1yo.5` OPEN** |
| **Version history** ("see all changes, restore one") | The literal `git log`; Restore = a forward re-apply commit (append-only) | `/_changes` · `rcp/changes` ✅ · `Git.log_entries/1` ✅ · `Git.diff/1` exists, **unwired** |
| **Draft** ("try a change, keep or discard") | A git **branch** in the same repo + a throwaway preview render on a `draft-<id>` subdomain; Keep = merge | branch + `PublicWeb` render + `pull` merge — **[NEW]**, no per-user branch exists today |
| **Deployed app link** ("share the live site") | A **PublicWeb URL** by DNS label; anyone-with-the-URL static serve | `public_web.ex`, `domains.ex:44-51` ✅ |
| **Private** ("my keys & notes never leave") | Auto-`.gitignore` egress boundary; one module for git+bundle+library | `Workbooks.Private` ✅ |
| **Mirror / Export** ("push to GitHub") | Whole-repo `git push` to any forge, or Radicle by DID | `git.ex:mirror/forge_push/publish` ✅ |

**Users see only the left column.** Every git noun (commit, branch, merge, HEAD, subtree, blame) stays behind the membrane.

**The monorepo is the spine.** `Library`'s own moduledoc says it: *"projecting workspaces to git is the MONOREPO."* A workspace is a `workspace.org` manifest whose members are subtrees (path or DID). Vendoring copies a member's whole subtree into a parent (`library.ex:592` `vendor/2` — "a DIRECTORY member → its whole subtree, each file keyed by repo-relative path so the tree round-trips on unpack"). That **is** the simplified monorepo the founder means.

---

## 2. Multi-level permissions — nexus / toolkit / workbook scopes compose

Permissions are **not one global mode**. They flex across three nested scopes, each narrowing the one above (intersection, never widening):

```
NEXUS scope        ── who can reach this running project at all (the workspace/org gate)
  └─ TOOLKIT scope ── per shared toolkit/folder: read | write | none (the vendored subtree's SCOPE)
       └─ WORKBOOK scope ── per workbook within: view | edit, + Access posture (public|gated_data|gated_route)
```

**How they compose (effective grant = the intersection):**
- **Nexus level** = the tenancy gate. `Tenancy.mode()` is `:single` (one shared workspace) or `:multi` (a verified JWT whose org **is** the tenant) (`tenancy.ex:17-25`). `Tenant.visible?(owner, caller)` is the one binary rule today: same-tenant-or-nil (`tenant.ex:46-48`). This is the *floor*; RBAC roles ride on top (`wb-g1yo.5` OPEN: "parse role from JWT; no RBAC exists today").
- **Toolkit / shared-folder level** = the member SCOPE. `Library.access(owner, requester, declared)` returns `read|write|none` and is **capped** by the declared scope ("the owner gets the declared scope — can't exceed it"; `library.ex:47-52`). A shared folder is exactly a `workspace.org` member with `:SCOPE: read|write`. Today cross-org grant resolves to `none` — that's the documented extension point and the RBAC work.
- **Workbook level** = `Access` posture (`access.ex`): `:public` / `:gated_data` / `:gated_route`, plus the per-workbook view/edit role. The anti-leak invariant (`static_safe?/1`) means a gated workbook can never be baked into a public artifact — a *capability* boundary, not a *permission* one, but it composes with the above (you can't "share publicly" what's gated).

**The team-of-one-with-multi-tenant-clients case.** A solo operator runs ONE workspace (their nexus) and builds client apps that are themselves multi-tenant (the client's app has its **own** auth — Clerk/WorkOS/whatever the client wired). The boundary:

- **Our permissions govern the workspace + the shared subtrees** — who can see/edit the *source*, the toolkits, the workbooks, the drafts. The operator is Owner; a client they invite to *review* is a Viewer on the relevant shared folder only.
- **The client app's own tenancy is THE CLIENT APP'S concern** — it runs behind `:gated_data`/`:gated_route` (`access.ex`) and resolves *its* users via *its* auth issuer (`deployment.org :AUTH: clerk`/`:ISSUER:`). Our RBAC never tries to model the client's end-users; it stops at the workspace membrane.

So tenancy is **layered, not global**: the operator's nexus is one tenant to *us*; inside, each deployed client app is its own multi-tenant world to *its* users. The deploy axis already carries this — `TENANCY_MODE` is per-deployment (`deploy.ex` templates), not per-platform. **Open:** wiring `Library.access` past owner-or-none into real per-member, per-role grants (`wb-g1yo.5/.6`).

---

## 3. The CRDT lock — an explicit, opinionated boundary

**State today: we have NO CRDT. Greenfield.** The WS bridge is stateless single-client RPC; board edits are last-write-wins line edits with no presence/lock/CRDT (`socket.ex`, `org_edit.ex`, `phoenix_socket.ex`). The grep for `crdt|yjs|automerge|presence|multi-cursor` over `runtime/host/` finds **nothing** (only unrelated "presence" = derived-storage and import-presence). Adopting CRDT is a from-scratch investment (a CRDT lib — Yjs/Automerge — a sync server, per-doc state, a persistence story, and a merge-into-git story). So the bar to put a surface in the CRDT column is **high**: it must genuinely need *live multi-cursor co-edit*, where last-writer or merge-on-save is unacceptable.

**The recommendation: the smallest honest CRDT footprint — which today is ZERO, and at most ONE surface later.**

### Surfaces that are GIT-SUBTREE-SYNC (last-writer / merge / pull-updates) — the default, almost everything

| Surface | Why subtree-sync is correct (not CRDT) |
|---|---|
| **Shared folders / vendored toolkits & workbooks** | The whole point is *receive updates*, not *co-type*. Pull-on-update + no-clobber merge (CODE/DATA lanes) is the Drive "newer version available" model. CRDT here would be absurd overkill. |
| **A workbook's `.org` source** | Commit-grained authorship; humans and the agent live on **disjoint lanes** (CODE vs DATA, `git.ex:240-243`) so same-file collisions are rare-by-design. Save = commit = merge. |
| **Drafts (branch + preview)** | A draft is one author's isolated branch; "Keep" is a merge. No two cursors. |
| **Deployments / published sites** | Read-only artifacts. No editing surface at all. |
| **Version history, changelog, restore** | Append-only log. Nothing to co-edit. |
| **Permissions / workspace.org manifest** | Config edited by Owner/Admin; last-writer + audit is fine. |
| **Agent commits** | The agent is a serial committer on a keeper tick — inherently single-writer per tick. |

### Surfaces that genuinely WANT CRDT (live multi-cursor) — at most one, and deferred

| Surface | Honest verdict |
|---|---|
| **Live co-editing one `.org`/board in the dashboard, two humans, same second** | This is the *only* surface where last-writer actually hurts (you'd stomp a teammate mid-keystroke). It's the Google-Docs/Figma-canvas fantasy. **Recommendation: do NOT build it for v1.** Sell "drafts + lanes + clear activity" (async), which the engine supports. If demand is real, scope a *single* CRDT surface — the org/board editor pane — using one lib (Yjs), a sync channel over the existing socket, and a **debounced flush to a normal git commit** so the CRDT is a transient edit buffer, never a second source of truth. The git log stays canonical; CRDT is just the live cursor layer on top. |
| **Presence ("Alex is here, cursor at line 40")** | Lightweight, *doesn't* need CRDT — it's ephemeral pub/sub over the socket. If you want a taste of "live", ship **presence-only** first (cheap, honest) and leave co-edit out. |

**The lock, stated plainly:** *Everything is git-subtree-sync. Presence is optional cheap pub/sub. CRDT is reserved for exactly one future surface — the live two-human org/board editor pane — and only as a transient buffer that flushes to git. We ship v1 with ZERO CRDT and do not promise real-time co-editing.* This is the founder's instinct, made precise.

---

## 4. The automation tie-in — agent-git-behavior + CI/CD + workflows + permissions are ONE authored system

The founder's framing: **agent git-behavior, CI/CD, workflow-automation, validations, and permissions are one connected system, authored like an agent profile / CI workflow.** The repo already has the three authored-as-org spines that converge here:

1. **Agent profile** (`agent_def.ex`) — an Org `:agent:` node: `:ID:`/`:MODEL:`/`:TOOLKITS:` props + a `** System prompt`. The agent's **git behavior** is host-brokered: it calls one `git` tool → `Git.commit_and_push/3` does add → commit (hooks off) → publish → maybe push (`git.ex:186-229`). The agent never runs raw git; the host decides the command line. So "what the agent commits, and when" is governed by the def + the keeper tick — **authored, not coded**.
2. **Workflow** (`workflow.ex`) — a native Org `:workflow:` headline **is** the DAG; `:component:` children are tasks, `:out→:in` args are edges, an `agent`-lang component runs the agent loop. "Org owns the orchestration spec; the runtime just executes it — no DSL, no board model." This is the in-runtime automation engine: validations, gates, and fan-outs are workflow steps.
3. **Deployment** (`deploy.ex` + `deployment.org`) — `wb deploy ci {github|gitlab|generic}` (`wb-6ttc.1` DONE) scaffolds CI that runs `wb deploy validate` on PRs and `apply`+`verify` on main, **from `deployment.org` as source of truth**. `TENANCY_MODE`/`AUTH`/`PROFILE` flow to the engine as env. This is the git-workflow-native CI/CD layer.

**The unification (the design claim):** these are the **same shape** — an authored Org artifact on the volume that declares *behavior + gates + identity*, hot-reloadable, autopoet-editable, never host `.ex`. The convergence is already doctrine:

- **`wb-mest`** (OPEN epic): dissolve the groundskeeper's host code into *agent def + toolkit + bridge spec*. `.mest.1` is a **declarative inbound tool-bridge** — an Org spec declares routes (name, auth mode, schema) → a named capability (toolkit CLI / **workflow** / agent). `.mest.3` migrates the dispatch lane to **an Org workflow** so the autopoet can tune it **without a deploy**. That is precisely "permissions + validations + automation authored as config."
- **Memory canon:** *"Behavior belongs in the config layer — host = primitives only."* Host keeps the generic inbound webhook primitive, HMAC/session auth, host-held creds, the supervised runner; everything else is Org on the volume.

**So the connected system reads as:** the **agent profile** says who-the-agent-is + its git/commit behavior; a **workflow** says the automated pipeline (author → validate → persist → run, with permission/validation gates as steps); **deployment.org** says where it runs + under what tenancy/auth + which CI reconciles it; and **`workspace.org` SCOPE + Access posture** say who may touch each subtree. All five are authored Org, all five hot-reload, none is host `.ex`. **The CI workflow ≈ the agent profile ≈ deployment.org — one authored substrate, three faces.** Reconciling with the Workflow engine: CI's `wb deploy` verbs and the in-runtime `Workflow` DAG are the **two execution surfaces** of that one substrate — CI for cross-repo/cross-push reconciliation (the outer loop), Workflow for in-nexus orchestration (the inner loop). Don't build a third.

**Open decision:** whether permission *changes* (grant/revoke a shared folder) are themselves a workflow step (authored, audited, agent-proposable via autopoet) or a direct API mutation. The `wb-mest` direction argues for authored; `wb-g1yo.6` (explicit sharing endpoints) implies direct. Recommend: **mutation via API, but the policy that governs who-may-grant lives in the authored layer** (role in the def/manifest), so the *rule* is config even if the *act* is an endpoint.

---

## 5. The happy paths (revised) — Drive vocabulary

Design stance: **Changes / Restore / Draft are kept as-is; Share + Collaborate are recast around shared folders + vendoring + the CRDT lock, all in Google-Drive words.** Each maps to an existing primitive or is tagged **[NEW]**.

### 5a. Changes / History — *unchanged from v1* (ship first)
Reverse-chronological timeline from `/_changes`/`rcp/changes` (real git log). Each entry tagged **Agent** (robot glyph) or **You/Teammate** (person glyph). Dashboard keeps human entries first-class and folds agent keeper churn into quiet "12 automatic updates". Click → before/after **prose** (needs `Git.diff/1` wired to an endpoint). **Restore = a forward re-apply commit** ("Restored to yesterday 4:00p"), never `reset --hard` — append-only, honors the changelog-is-verifiable rule.

```
┌─ Changes ───────────────────────────── waldo: working · next run 2:14 ┐
│  ● today 3:04p   AGENT   added "Spring sale" section          ⤿ view  │
│  ● today 1:20p   YOU     renamed pricing tiers                ⤿ view  │
│  ▸ ⌄ 12 automatic updates by waldo · 11:00a–12:40p                    │
│  ● yest  6:12p   ALEX    fixed hero headline                  ⤿ view  │
│              ┌─ added "Spring sale" section ────────────────────────┐ │
│              │  + Spring sale — 20% off through Friday              │ │
│              │  [ Restore this version ]   [ Compare to now ]       │ │
│              └──────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### 5b. Drafts / What-if — *unchanged from v1*
Reframe "branch" → **Draft**: a named isolated working copy, **preview live** on `draft-<id>.<nexus>`, then **Keep** (merge, no-clobber `pull` logic) or **Discard** (delete branch). **[NEW]** — no per-user branch exists today. Tier 1 = branch + preview render (cheap, ship first); Tier 2 = forked-nexus preview (defer). This is the single feature that makes git's killer capability feel safe.

### 5c. Shared folders (recast Collaborate) — *the Drive reframe*

**Old framing ("Collaborate") → new framing ("Shared folders").** Collaboration is not a live canvas; it is **folders shared between workspaces, that receive updates** — exactly Google Drive. People work async in **Drafts** and on disjoint **lanes**; we make activity legible, never pretend multiplayer (the CRDT lock §3).

**Backed by:** `workspace.org` MEMBERS/SCOPE (parsed; enforcement = `wb-g1yo.5` OPEN) + `Library.pack/install` (vendoring ✅) + `git.ex:pull` (update-merge ✅) + WorkOS membership/roles (`TEAM-SHARING-DESIGN`, mostly not our code).

**Walkthrough.**
1. **My folders** = the workspace's members. Each shows a share state ("shared with Acme · they can view") and, if vendored from elsewhere, an **Update available** chip when the source has newer bytes (a `pull` diff).
2. **Share a folder** = grant a workspace member (or another workspace) a SCOPE — *view* (read) or *edit* (write). Under the hood this is the `workspace.org` member's `:SCOPE:` + a cross-org grant (the `Library.access` extension point).
3. **Add a shared folder to my workspace** = **vendor it in**: `Library.fetch → install`, landing as a tracked subtree that future **Update** pulls keep current.
4. **Conflict, reframed [NEW]:** when an Update or a Draft-Keep hits `{:conflict, files}`, show *"Both you and Alex changed the pricing section — pick one"* with two prose versions + Keep mine / theirs / both, then commit the resolution (drive the existing merge/abort).

```
┌─ Shared folders · acme workspace ─────────────────────────────────────┐
│  My folders                                                            │
│   📁 Brand book        shared with Acme · they can view    [ Manage ]  │
│   📁 Pricing toolkit   vendored from "agency-kit"  ⟳ Update available   │
│   📁 Launch deck       private                              [ Share ]   │
│                                                                        │
│  ┌─ Share "Brand book" ────────────────────────────────────────────┐  │
│  │  Add people or a workspace…                                      │  │
│  │   alex@acme         can edit ▾                                   │  │
│  │   Acme (workspace)  can view ▾                                   │  │
│  │  🔒 Private: your keys, memory, task notes never leave.          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│  ┌─ Update "Pricing toolkit"? ─────────────────────────────────────┐  │
│  │  The source has 3 newer changes. ✓ No conflicts.   [ Update ]    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
```

### 5d. Share (the chooser) — recast around the three real share kinds

Three honest things you can share, one chooser, all Drive words:
- **Shared folder** (people/workspaces) — grant view/edit on a subtree (§5c). The collaboration path. *Backed by SCOPE + vendoring; enforcement OPEN.*
- **Deployed app link** — the live site URL (`PublicWeb`). Anyone with the link opens it. Show the leak-guard: a `gated_route` workbook explains why it can't be public (`Access` already refuses). *Exists.*
- **View link [NEW]** — "anyone with this link can view" capability URL: `PublicWeb` static render + a signed, optionally-expiring token. View-only; "link can edit" is explicitly out (no live co-edit).

```
┌─ Share "acme pricing" ────────────────────────────────────────────────┐
│  ( ) Shared folder   People / workspaces, view or edit                │
│  (•) View link       Anyone with the link can view   expires 7 days ▾ │
│        https://acme.workbooks.app/s/9f3c2ab…          [ Copy link ]    │
│  ( ) Deployed app    The live site URL — anyone can open              │
│        ⚠ gated data: publishing exposes only the public layer.        │
│  ── advanced ───────────────────────────────────────────────────────  │
│  Export whole project to GitHub / GitLab        [ Connect a forge ]   │
└───────────────────────────────────────────────────────────────────────┘
```

**Opinion:** "Export to GitHub" is the anti-lock-in **advanced** affordance, not the primary button — it's *export*, not *share*. The primary verbs are **Shared folder** (collaborate) and **link/app** (publish).

---

## 6. Phased build proposal (smallest-first) + open decisions

| Phase | What | Existing primitives | New work | Beads |
|---|---|---|---|---|
| **1 — Changes + Restore** ⭐ | Dashboard Changes tab; human/agent classification (invert the lander's collapse); before/after prose; Restore = forward re-apply | `/_changes`·`rcp/changes`·`Git.log_entries` ✅ | wire `Git.diff/1` to an endpoint; Restore verb | — (pure wiring) |
| **2 — Share: View link + Deployed app** | The chooser (link + app), leak-guard messaging | `PublicWeb`·`Access`·`Workbooks.Private` ✅ | signed/expiring view-link token on the static plane | `wb-g1yo.6` (sharing) |
| **3 — Shared folders (vendoring + update)** | "Add to my workspace", "Update available", share-a-folder | `Library.pack/install` ✅·`git.ex:pull` ✅·`workspace.ex` parse ✅ | **enforce** SCOPE; cross-org grant; Update-diff UI; conflict UX | `wb-g1yo.5` RBAC (OPEN), `wb-39j` federation ✅ |
| **4 — Multi-level RBAC** | nexus/toolkit/workbook scope composition; team-of-one-multi-tenant-client model | `Tenant.visible?`·`Access` postures·`deploy TENANCY_MODE` ✅ | role from JWT; `Library.access` past owner-or-none; intersection enforcement | `wb-g1yo.5` (OPEN) |
| **5 — Drafts + conflict UX** | branch + `draft-<id>` preview; Keep=merge; Discard; conflict picker | `pull` merge ✅·`PublicWeb` render ✅ | per-user draft branch; preview subdomain; conflict resolution commit | — (defer Tier 2 forked-nexus) |
| **6 — Team + person attribution** | WorkOS members widget + seat strip; per-commit person author; activity strip | WorkOS (mostly not our code) | bridge WorkOS identity → commit author env at commit time | rides `TEAM-SHARING-DESIGN` |
| **7 — (defer) Live co-edit** | ONE CRDT surface (org/board pane), presence-first | socket ✅ | Yjs buffer flushing to git commit; presence pub/sub | **only if demand proves it** |
| **— (parallel) Automation-as-config** | agent-git + CI/CD + workflow + permissions authored as Org | `agent_def`·`workflow`·`deploy ci` ✅ | bridge spec, dispatch-as-workflow | `wb-6ttc` (.1 done), `wb-mest` (OPEN) |

**Explicitly NOT building for v1:** real-time multiplayer co-editing (no CRDT — §3); the absent external desktop network-broker; the dangling `/api/publish` route.

### Open decisions that remain (for the founder)

1. **CRDT lock — confirm zero for v1.** Agreed that everything is subtree-sync, presence is optional, and CRDT is reserved for exactly one future org/board pane (transient buffer → git)? Or is there a surface you consider truly-live that I've put in the wrong column?
2. **Vendoring update semantics.** When a shared folder's source updates, is it **pull-on-demand** (user clicks Update — recommended, Drive-like, no surprise overwrites) or **auto-pull** on the keeper tick? And does a vendored subtree the recipient **edited locally** keep its edits (CODE/DATA-lane split) or is the source authoritative?
3. **Multi-level RBAC shape.** Confirm the intersection model (nexus ∩ toolkit ∩ workbook, never widening) and that the **client app's own tenancy is out of our scope** — we stop at the workspace membrane, the client app resolves its own users via its own `:AUTH:`.
4. **Where the permission *act* lives.** Grant/revoke via direct API (with the *policy* of who-may-grant in the authored layer), or grant/revoke itself as an authored, audited, autopoet-proposable workflow step (`wb-mest` direction)?
5. **Restore semantics.** Confirm Restore = forward re-apply commit (append-only). Any case users expect literal history erasure (which we'd refuse on brand grounds)?
6. **Single vs multi in the dashboard.** Cloud dashboard runs `:multi` (WorkOS-org-per-tenant); `:single` is desktop/local only? This decides whether person-attribution and Team are even meaningful.
7. **Draft model.** Branch + render (Tier 1, cheap, ships sooner) vs forked nexus (Tier 2, DB-level previews). Start Tier 1? And can the **agent** open a Draft for human review (an approval gate) vs committing straight to live?
8. **View-link defaults.** View-only only (recommended)? Default expiry (7d?) and is "no expiry" allowed?
9. **Public leak-guard UX.** When `Access` refuses a gated workbook, block-with-explanation or offer "publish only the public layer"? (Mock assumes the latter.)
10. **Vocabulary lock.** Sign off before any UI: **Changes / Restore / Draft / Keep / Discard / Shared folder / Add to my workspace / Update / View link / Deployed app / Private / Export** (renaming later is expensive).
```
