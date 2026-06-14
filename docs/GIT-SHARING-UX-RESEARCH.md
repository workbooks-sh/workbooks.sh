# Git / Sharing / Version-Tracking UX — Research & Design

*Date: 2026-06-14. RESEARCH + DESIGN ONLY — no code, no app-file changes. Goal: agree the clean happy paths for exposing git's power (history, drafts, attribution, collaboration, sharing) to Workbooks cloud-dashboard users BEFORE any build. Companion to `docs/TEAM-SHARING-DESIGN.md` (workspace = WorkOS org, roles, seats), `docs/AUTH-LAYERING-RESEARCH.md`, `docs/HOSTED-NEXUS-ECONOMICS.md`, and the learn surfaces (`web/learn/git.html`, `gitops.html`, `sharing.html`, `who-sees-what.html`, `changelogs.html`).*

> Grounded strictly in the system maps + the code/learn surfaces they cite. New ideas are tagged **[NEW]** with the primitive they build on. Don't invent capabilities.

---

## 0. The one-paragraph thesis

The running project **is** a git repo (not "integrates with git"). Each tenant gets a repo at `$WB_DATA/<tenant>` (`git.ex:16,28-42`); a workbook is one `.org` file; **every deploy is a commit** that atomically commits-publishes-pushes (`git.ex:160-169,186-229`). Both humans **and agents** write commits. History is free because everything is text; SQLite is a rebuildable projection, never a second master. The job here is **not** to build a version-control system — it's to put a clean, plain-language face on the one we already have, hiding raw git nouns (commit/branch/merge/HEAD) behind words a non-technical founder and a developer both trust.

---

## 1. How it works today (plain-language synthesis of the maps)

**The repo per tenant.** One git repo per tenant/workspace, initialized the moment the project starts. The `.org` source is the canonical master; the live database is a derived index that can be dropped and replayed from git. (`git.ex:16,28-42`; `ORG-SUBSTRATE-ENGINE-DESIGN.md`.)

**Save = commit = publish, in one breath.** `Git.save/3` writes `name.org`, adds, commits `deploy: <name>`, returns the HEAD sha or `nochange` (`git.ex:160-169`, only caller `workbooks.ex:18`). The agent's single git tool does add → commit (hooks off) → **publish** → maybe push to origin (`agent.ex:311-334`, `git.ex:186-229`). "Committed" always implies "live" — welded together to fix a real scar (a lander committed blog posts that served 404 because a separate publish step never ran).

**Who made a change.** Attribution is at **commit granularity = the tenant** (author = tenant, `tenant@workbooks.local`; `git.ex:22-25,326-333`). Under that sits real crypto: a per-tenant Ed25519 `did:key` (`git.ex:67-78,108-111`) that signs the run's step-log ledger head — **not** individual file lines. **There is no `git blame` anywhere.** A "who changed this line" view would be built from scratch.

**The history feed = the literal git log.** A deployed app serves `GET /_changes` (anonymous, read-only, newest-first, ~30 entries: `sha/ts/author/msg`) plus keeper status (`public_web.ex:39-51`); `web.ex` exposes `rcp/changes` (`1022-1034`); the lander polls every ~15–20s (`stores.js:581-590,1064-1089`). Hard brand rule: **the changelog is verifiable history, not marketing** — you may never curate/editorialize it.

**The shipped tracking UX (the only one).** The living-lander `#timeline` panel: classify each commit by its **message tag** (`add:`/`rem:`/`compose:`/`strategy:`/`blog:`/`audit:`/`plan:`/`keeper:` → `/^([a-z]+):/`), map each to a **who** (agent "waldo" vs human) and a brand color, collapse consecutive human commits into one quiet "N updates by the team" group so agent work stands out, link each node to the real commit, show relative time, and pair it with live keeper state + a "follow along" cursor that narrates the run with **sanitized** labels only — never URLs/args/keys (`stores.js:581-683,795-1045,286-306`).

**The two-direction loop (no-clobber).** Outbound: agent commits flow out as the public changelog. Inbound: human/CI pushes are **merged** on the keeper tick (`WB_GITOPS=1`), never overwritten (`gitops.html:235-306`). The guarantee is a convention: two disjoint lanes — **CODE** (`app/src/`, agent def, `design.org`, `skills/` — humans/CI) vs **DATA** (`content/`, `blog/`, `plan.org`, `rem/` — the agent). Same-file divergence stops as `{:conflict, files}` + `merge --abort`, "left for a human." (`git.ex:253-301`.)

**Isolation = tenancy, and only tenancy.** Tenant is the broker principal (`tenant.ex:22-32`). `Tenancy.mode()` is `:single` (everyone shares one workspace) or `:multi` (JWT whose org **is** the tenant) (`tenancy.ex:17-25`, `auth.ex`). Visibility is one binary rule everywhere: **same-tenant-or-nil** (`tenant.ex:46-48`). There is **no sub-structure inside a tenant** — no teams/seats/members/ACL/grants. Workbook ownership is an `(id, org, tenant)` SQLite row with **no share/permission columns** (`control_plane.ex:36-57`).

**Sharing today = two blunt instruments.** (1) **Public publish:** `PublicWeb` is a separate auth-free GET-only plane serving static published bytes by DNS label (`public_web.ex`, `domains.ex:44-51`) — anyone-with-the-URL, no per-visitor auth, no link permissions/expiry. `Access` only guards against baking a *gated* workbook into a public artifact (a leak guard, not a permission system). (2) **Mirror/federate:** push the **whole tenant repo** to GitHub/GitLab/Gitea, or Radicle by DID (`web.ex:1056-1102`) — "share my repo," not "collaborate on a workbook."

**Privacy boundary (load-bearing).** `Workbooks.Private` is the single source of truth (consulted by Git, bundler, Library) that auto-writes `.gitignore` (signing key, `memory/`, `.beads/`, `.claude/`, run sidecars). Doctrine: **sharing exposes WORK, never the session** (keys/memory/beads). Any new sharing egress must route through this one module. It exists because beads task data once leaked to GitHub.

**What's parsed-but-unwired (don't assume it works):**
- `workspace.org` **MEMBERS** with `read|write` SCOPE — pure data parsing, **nothing enforces it**; `/api/workspaces/sync` is a stub (`workspace.ex`, `web.ex:105-107`).
- `ledger.ex seal/anchor`, `jj.ex oplog`, `Git.diff/1` — **zero callers / no endpoint**.
- Desktop network-share (recipients[], posture public|friends|group|private, fork/install) routes to an **external broker absent from this repo** (`network.svelte.ts`).
- `publish.ex` self-hosted target POSTs `/api/publish` — **no such route exists**.

---

## 2. The core UX problems (what's genuinely hard)

1. **Agents are first-class committers.** Most version-control UIs assume humans make changes and review each other. Here a tenant's biggest "author" is an agent committing on a keeper tick. The UX must make **human vs agent** legible at a glance and never let agent volume bury human intent (the lander's "collapse humans into a quiet group" instinct is actually backwards for a *dashboard* where the human is the owner — see §3a).

2. **Attribution is coarse.** Author = tenant, not a person; no per-line blame. In `:single` mode "everyone is the same author." In `:multi` mode the JWT org is the tenant, so still one author per workspace. A truthful "who did this" needs a **new** person-level identity layer riding on top of WorkOS membership — we cannot fake per-line blame we don't have.

3. **Branch/merge jargon is poison for non-technical users** but the underlying capability (try a change safely, keep or discard) is exactly what they want. The hard part is delivering preview-and-keep **without** a branch model the engine doesn't currently expose (today there's only `main` + the inbound-merge loop; no per-user branches).

4. **Conflict is real but rare-by-design.** The lane convention keeps humans and the agent off the same files. But two *humans* (multi-user) hitting the same `.org`, or a human editing a DATA file the agent owns, will collide. Today that surfaces as `{:conflict, files}` + abort — a dead end with no user-facing resolution UX.

5. **Sharing scope is binary and blunt.** "Anyone with the URL" (public static) or "whole repo to a git host" or "same-tenant-only." There is **no** middle: no view-link, no per-recipient access, no expiry, no "share with these 3 people." Users will expect Notion/Figma-grade sharing controls that simply don't exist yet.

6. **Collaboration has no live layer.** The WS bridge is stateless single-client RPC; board edits are last-write-wins line edits with no presence/lock/CRDT (`socket.ex`, `org_edit.ex`). Two people cannot co-edit through any live path. We must **not** promise Google-Docs real-time; we design async collaboration honestly.

7. **Honesty constraints bind every screen.** Changelog must be the literal log (no curation). Egress must pass `Workbooks.Private`. Pitch rule: "software built in workbooks," never "sites that run themselves." Sanitized narration only.

---

## 3. The happy paths (designed flows + ASCII mocks)

Design stance: **four verbs, plain words** — *History*, *Drafts*, *Collaborate*, *Share*. Each maps to an existing primitive where one exists, and is tagged **[NEW]** where it doesn't.

### 3a. History / Changes — "what changed, by whom, and roll it back"

**Backed by:** `GET /_changes` / `rcp/changes` (real git log) — *exists*. Restore — **[NEW]** thin wrapper over git (revert/reset) exposed as one endpoint; `Git.diff/1` exists but is **unwired** → needs an endpoint.

**Walkthrough.** Owner opens a nexus → **Changes** tab. A reverse-chronological timeline of entries, each tagged **Agent** (robot glyph, live-green) or **You/Teammate** (person glyph, neutral). Unlike the public lander (which *hides* humans), the dashboard **keeps human entries first-class** and instead groups *agent* keeper churn into quiet "12 automatic updates" folds — because here the human owner is the audience. Click an entry → plain-language summary + a **diff rendered as before/after prose**, not a unified patch. Two actions: **Restore this version** (makes the old state the new latest — implemented as a forward commit, never destructive history rewrite) and **Compare to now**.

```
┌─ Changes ───────────────────────────── waldo: working · next run 2:14 ┐
│                                                                       │
│  ● today 3:04p   AGENT   added "Spring sale" section          ⤿ view  │
│  ● today 1:20p   YOU     renamed pricing tiers                ⤿ view  │
│  ▸ ⌄ 12 automatic updates by waldo · 11:00a–12:40p                    │
│  ● yest  6:12p   ALEX    fixed hero headline                  ⤿ view  │
│  ● yest  4:00p   AGENT   published 3 blog posts               ⤿ view  │
│                                                                       │
│  [ view ] →  ┌─ added "Spring sale" section ──────────────────────┐  │
│              │  + Spring sale — 20% off through Friday            │  │
│              │  + [Shop now] button → /sale                       │  │
│              │                                                    │  │
│              │  [ Restore this version ]   [ Compare to now ]     │  │
│              └────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
```

**Opinion:** ship this first (it's ~entirely wiring existing endpoints) and make **Restore** a *new commit that re-applies an old tree* ("Restored to yesterday 4:00p") — never `reset --hard`. History stays append-only and verifiable, honoring the changelog rule.

### 3b. Drafts / What-if — "try a change, keep it or throw it away"

**Backed by:** Today there is only `main` + the inbound-merge loop. **No per-user branches exist.** This is the **most [NEW]** path. Build on: the WIP/merge-snapshot machinery in `pull/1` (`git.ex:253-301`) and the lane convention.

Reframe "branch" → **Draft**. A Draft is a named, isolated working copy of the workbook the user (or agent) can change freely, **preview live**, then **Keep** (merge to the live nexus) or **Discard**.

**Recommended implementation [NEW], two tiers:**
- **Tier 1 (cheapest, ship first): in-repo draft branch + preview render.** A Draft is a git branch in the same tenant repo; "Preview" renders that branch's `.org` to a throwaway static artifact on a `draft-<id>.<nexus>` subdomain (reuses `PublicWeb` static-render + `Domains` label resolution). "Keep" = merge the draft branch into the live branch through the existing no-clobber merge (`pull/1` logic), surfacing `{:conflict, files}` to the §3c conflict UX. "Discard" = delete the branch. *No new infra; it's branch + render + the merge we already have.*
- **Tier 2 (later, only if needed): forked nexus preview** — a full second runtime instance with its own DB projection (a la Neon/Vercel preview). Heavier; defer until Tier 1 proves the model.

```
┌─ Drafts ──────────────────────────────────────────────────────────────┐
│  Live nexus: acme.workbooks.app                          [ + New draft ]│
│                                                                         │
│  ◇ "holiday-redesign"   you · 2 changes        preview ↗   [Keep][Discard]│
│  ◇ "agent-pricing-test" waldo · 1 change       preview ↗   [Keep][Discard]│
│                                                                         │
│  ┌─ Keep "holiday-redesign"? ───────────────────────────────────────┐  │
│  │  This applies 2 changes to your live nexus.                      │  │
│  │  ✓ No conflicts — your live site keeps everything else.          │  │
│  │  [ Keep & publish ]                                  [ Cancel ]   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

**Opinion:** call them **Drafts**, never "branches." One live nexus, many drafts, each previewable on its own URL, kept or discarded. This is the single feature that makes git's killer capability feel safe to a non-technical founder.

### 3c. Collaborate — "teammates editing, who's doing what, conflicts handled"

**Backed by:** **Real isolation today is tenancy only.** The `workspace.org` MEMBER/SCOPE model is parsed-not-enforced. The **new** collaboration substrate is `docs/TEAM-SHARING-DESIGN.md`: **workspace = WorkOS Organization**, members = WorkOS memberships with **Owner/Admin/Member/Viewer** roles, invites via WorkOS — *self-managing, mostly not our code*. That doc is the dependency this path rides on.

**Honesty:** no real-time co-editing (no CRDT/presence). Design **async** collaboration: people work in **Drafts** (§3b) and on disjoint **lanes** (§1), and we make activity legible rather than pretending to multiplayer.

**Walkthrough.**
1. **Team** view = the embedded WorkOS User Management widget (members table, invite, role edit) — per TEAM-SHARING-DESIGN; we build the shell + seat strip only.
2. **Person-level attribution [NEW]:** in `:multi` mode the commit author is still the tenant/org. To show "Alex changed this," bridge the **WorkOS member identity into the commit author/committer env** at commit time (we already set `GIT_AUTHOR`/`COMMITTER` from one identity — `git.ex:326-333`; the new bit is sourcing the *person* from the authenticated session, with the tenant kept as committer for the ownership invariant). This gives truthful per-commit (not per-line) person attribution.
3. **Activity:** a "who's working on what" strip listing open Drafts by person + the agent's live keeper status (reuse `/_changes` + keeper status + the Drafts list).
4. **Conflict, reframed [NEW]:** when "Keep a Draft" hits `{:conflict, files}`, don't dump a merge error. Show: *"Both you and Alex changed the pricing section. Pick the version to keep."* with the two prose versions side by side and a **Keep mine / Keep theirs / Keep both** choice, then commit the resolution. (Underneath: drive the existing merge/abort, then commit the chosen tree.)

```
┌─ Team · acme workspace ───────────────────────────────────────────────┐
│  [WorkOS members widget: avatar · name · email · role · last active]   │
│  Seats: 4 / 10 included                                  [ Invite ]    │
├─ Activity ────────────────────────────────────────────────────────────┤
│  waldo (agent)   working · publishing blog              live           │
│  Alex            draft "holiday-redesign" · 2 changes   12m ago        │
│  You             draft "agent-pricing-test"             just now       │
├─ Conflict on "Keep" ──────────────────────────────────────────────────┤
│  You and Alex both changed the Pricing section:                        │
│   Yours ▸ "Starter $9 / Pro $29"                                       │
│   Alex  ▸ "Starter free / Pro $19"                                     │
│   [ Keep mine ]   [ Keep Alex's ]   [ Keep both ]                      │
└─────────────────────────────────────────────────────────────────────────┘
```

**Opinion:** lean 100% on WorkOS for membership/roles (don't build a member CRUD). Person-level commit attribution is a small, honest, high-value [NEW]. Do **not** promise live co-editing — sell "drafts + lanes + clear activity," which the engine actually supports.

### 3d. Share — "give people access: view link, team, or public"

**Backed by:** Public publish (`PublicWeb`) *exists*; whole-repo mirror *exists*; `Access` `:public/:gated_data/:gated_route` *exists* (`who-sees-what.html`). Roles come from WorkOS (TEAM-SHARING-DESIGN). **What's missing:** scoped per-recipient/view links with expiry.

**Three honest share modes (match `who-sees-what.html` vocabulary), one chooser:**
- **Team** — visible to workspace members per their WorkOS role (Viewer can view, Member can edit). Backed by tenancy + roles. *Mostly exists* once roles are wired.
- **Public** — publish to a URL anyone can open (the static `PublicWeb` plane). *Exists.* Make the **leak guard visible**: if the workbook is `gated_route`, the UI explains why it can't be made public (don't silently fail — `Access` already refuses).
- **Link [NEW]** — a "anyone with this link can **view**" capability URL. Build on `PublicWeb` static render + a signed, optionally-expiring token resolved on the public plane (a token-gated variant of the existing static serve). Start **view-only**; "link can edit" is explicitly out of scope (no live co-edit).

All egress routes through `Workbooks.Private` so keys/memory/beads never ship — surface this as a quiet "Private: your keys & notes never leave" reassurance line.

```
┌─ Share "acme pricing" ────────────────────────────────────────────────┐
│  ( ) Team        Workspace members by role        Viewer ▾            │
│  (•) Link        Anyone with the link can view    expires: 7 days ▾   │
│      https://acme.workbooks.app/s/9f3c2ab…           [ Copy link ]     │
│  ( ) Public      Anyone on the internet                               │
│        ⚠ This workbook has gated data — publish exposes only the      │
│          public layer; locked sections stay private.                  │
│                                                                        │
│  🔒 Private: your keys, memory, and task notes never leave the nexus.  │
│  ── advanced ──────────────────────────────────────────────────────── │
│  Mirror whole project to GitHub / GitLab        [ Connect a forge ]    │
└─────────────────────────────────────────────────────────────────────────┘
```

**Opinion:** the **Link** mode is the highest-leverage [NEW] sharing primitive (it's what Notion/Figma users reflexively reach for) and it's a modest extension of the static plane. Keep "mirror whole repo" as an **advanced/anti-lock-in** affordance, not the primary share button — it's "export," not "share."

---

## 4. Vocabulary (user-facing words)

Drop raw git nouns. Honor existing brand vocabulary (deploy/changes/keeper/lanes/nexus/workspace/private).

| Git concept | ❌ Don't say | ✅ Say (user-facing) |
|---|---|---|
| commit | commit, SHA, HEAD | **change** / **update** (an "update to your nexus") |
| commit message | commit message | **what changed** (the summary line) |
| git log / changelog | log | **History** / **Changes** |
| revert/reset | reset, revert | **Restore** ("Restore this version") |
| branch | branch, checkout | **Draft** ("a draft of your changes") |
| merge (keep draft) | merge | **Keep** ("Keep & publish") |
| delete branch | delete branch | **Discard** |
| merge conflict | conflict | **"Both changed the same thing — pick one"** |
| author/committer | author | **who** (Agent / You / teammate name) |
| diff | diff, patch | **before & after** (prose) |
| push/publish | push | (silent — "Published" / "Live") |
| remote/mirror | remote, origin | **Mirror / Export to GitHub** (advanced) |
| repo | repo | **project** / **nexus** (the running thing) |
| workspace/org/tenant | tenant, org | **Workspace** |
| public static | static artifact | **Public** |
| capability link | token URL | **Link** ("anyone with the link") |
| ignored / private | .gitignore | **Private** ("never leaves the nexus") |
| agent commits | — | **waldo / the agent** (named, robot glyph) |

Two load-bearing brand phrases to keep: **"every change is saved, nothing is lost"** (history-as-free), and **"sharing exposes your work, never your keys"** (the `Workbooks.Private` boundary).

---

## 5. Real-world analogs — borrow vs avoid

| Product | Borrow | Avoid |
|---|---|---|
| **Notion / Google Docs version history** | Plain timeline, "Restore this version," human-readable entries, append-only restore. The mental model to copy for §3a. | Their per-keystroke granularity (we're commit-grained); pretending edits are real-time. |
| **Figma branching** | "Branch" reframed as a safe place to try things, **preview**, then merge back; review-before-merge. Great model for §3b **Drafts**. | The word "branch"; their full live-multiplayer canvas (we have no CRDT). |
| **Vercel / Neon preview deploys** | A draft gets its **own live preview URL** (`draft-<id>.<nexus>`); "promote to production" = Keep. Directly informs §3b Tier 1. | Spinning a full second runtime per draft (Tier 2) before it's needed — start with branch+render. |
| **GitHub Desktop** | Honest history + clear "who"; conflict shown as concrete file/section choices. | Exposing raw git verbs/SHAs/terminal feel; it's a tool for devs, our floor is non-technical. |
| **Linear** | Crisp activity feed, who-did-what, calm density; roles. | Issue-tracker framing — our unit is the nexus + its changes, not tickets. |
| **Notion/Figma share dialog** | The 3-mode chooser (Team role / Link / Public) with expiry — the exact §3d shape. | Granular per-block ACLs we can't enforce; "link can edit" (no live co-edit yet). |

**North star blend:** *Google Docs history × Figma drafts × Notion share dialog × Vercel preview URLs* — all sitting on the honest, verifiable git log, never a curated timeline.

---

## 6. Phased build proposal + open questions

### Phase 1 — **History + Restore** (smallest first useful slice) ⭐
The #1 first slice. Almost pure wiring of endpoints that exist.
- Dashboard **Changes** tab consuming `/_changes` / `rcp/changes` (already live).
- Human/agent classification (reuse the lander's tag/`who` logic), but **invert the collapse**: humans first-class, agent keeper churn folded.
- **[NEW] endpoints:** expose `Git.diff/1` (currently no endpoint) for before/after; a **Restore** verb = a forward "re-apply old tree" commit (never destructive).
- Render diffs as before/after prose, not patches.
- **Why first:** delivers the headline promise ("nothing is lost, restore anything") with minimal new surface, validates the human-vs-agent UX, and ships independent of WorkOS.

### Phase 2 — **Share: Link + Public chooser**
- The 3-mode share dialog (§3d). **Public** + leak-guard messaging reuse `PublicWeb`/`Access` (exist).
- **[NEW]:** the **view-only Link** (signed/expiring token on the static plane). **Team** mode lights up fully once Phase 3 roles land; ship Link+Public first.
- All egress asserted through `Workbooks.Private`.

### Phase 3 — **Team + person attribution** (rides TEAM-SHARING-DESIGN)
- Embed WorkOS User Management widget + seat strip (per that doc; mostly not our code).
- **[NEW]:** bridge WorkOS person identity into commit author at commit time → truthful per-commit attribution. Activity strip.

### Phase 4 — **Drafts (what-if)** + conflict UX
- **[NEW]** Tier 1: draft branch + preview render on `draft-<id>` subdomain; Keep = existing no-clobber merge; Discard = delete branch.
- **[NEW]** Conflict UX (§3c) over the existing `{:conflict, files}`/abort path.
- Defer Tier 2 (forked-nexus preview) unless demand proves it.

*(Explicitly NOT building: real-time multiplayer co-editing — no CRDT/OT; the absent external desktop network-broker; the dangling `/api/publish` route.)*

### Open questions for the founder (the genuine decisions)

1. **Restore semantics.** Confirm: Restore = *new forward commit re-applying an old tree* (append-only, verifiable). Agreed? Any case where users will expect literal history erasure (which we'd refuse on brand grounds)?
2. **Single vs multi tenancy in the dashboard.** The cloud dashboard presumably runs `:multi` (WorkOS-org-per-tenant). Confirm — it changes whether person-attribution and Team are even meaningful, and whether `:single` (shared-author) is only a desktop/local mode.
3. **Draft model: branch (Tier 1) vs forked nexus (Tier 2)?** Branch+render is far cheaper and ships sooner; forked nexus gives true DB-level previews (Neon-style). Start Tier 1?
4. **Who can make Drafts/Restore — and can the agent?** Agents already commit. Should an agent open a **Draft** for human review before going live (an approval gate), or keep committing straight to live? This is a product-shape decision about human-in-the-loop.
5. **Link sharing default & expiry.** View-only only (recommended), or is an "edit link" ever on the roadmap (would force a live-collab investment we don't have)? Default expiry (7d?) and is "no expiry" allowed?
6. **Public leak-guard UX.** When `Access` refuses to publicly-publish a gated workbook, do we (a) block with explanation, or (b) offer "publish only the public layer"? §3d assumes (b).
7. **Conflict ownership.** When two humans conflict, who's allowed to resolve — anyone, or only Owner/Admin? Ties to WorkOS roles.
8. **Vocabulary lock.** Sign off on **Changes / Restore / Draft / Keep / Discard / Link / Team / Public / Private** before any UI is built (renaming later is expensive).
9. **Mirror placement.** Is "mirror whole repo to GitHub" an advanced/export affordance (recommended) or a primary share path for dev users?
