# OSS boundary — Collaborative Workspaces wrapper

*Phase 7 of the collaborative-workspaces direction. This document DEFINES what would
be open-sourced and how; it does not publish anything. Cutting an OSS release is an
irreversible founder decision — see "Before you publish" at the end.*

## The pitch (one breath)
**A Drive-simple monorepo for AI-built software** — share a folder, add a toolkit,
undo anything; subtree-synced workspaces with append-only history. Every competitor
in this space is a developer tool; nobody packages subtree-sharing + history/undo
behind a non-technical Drive metaphor. We open-source that **wrapper**; the **moat**
(hosted sync, shared build cache, the in-wasm polyglot build) stays commercial.

## The line — what's OSS vs commercial

| Open source (the wrapper) | Commercial (the moat) |
|---|---|
| History + Restore (append-only) | Hosted, always-on sync + provisioning (Fly/R2/Neon) |
| Undo | Shared **build cache** (Nx-Cloud model) |
| Shared folders (subtree share/add) | The **in-wasm polyglot build** lane (`package_manager.ex`, content-addressed `build/cache/<sha>`) — the real moat |
| Drafts (try safely · Keep/Discard) | Multi-region, scale-to-zero nexus hosting |
| Multi-level RBAC (the decision engine) | Billing, usage metering, the dashboard SaaS |
| GitHub/GitLab backup (one-way lens) | Platform-plane auth + org management |
| App-auth integration surface (claim-map) | |

Rationale: the wrapper is the adoption surface (low-stakes, copyable, a real market
gap); the moat is the operationally hard part that's worth paying for. This mirrors
how `josh`/`jj` are MIT/Apache while the hosted products around them are not.

## The OSS module set (extraction manifest)

These runtime modules form the wrapper. Each is pure policy/orchestration over a
git store + a tenant boundary — no Fly/R2/Neon/billing coupling, so they lift cleanly.

| Module | File | Public surface |
|---|---|---|
| `Workbooks.History` | `runtime/host/history.ex` | `timeline/2` · `diff/3` · `restore/3` · `undo/2` |
| `Workbooks.Draft` | `runtime/host/draft.ex` | `create/2` · `list/1` · `diff/2` · `keep/2` · `discard/2` |
| `Workbooks.SharedFolder` | `runtime/host/shared_folder.ex` | `share/4` · `shared_by/1` · `shared_with/1` · `add_to_workspace/2` · `revoke/2` |
| `Workbooks.RBAC` | `runtime/host/rbac.ex` | `can?/3` · `subject/2` · `roles/0` · `capabilities/1` |
| `Workbooks.Backup` | `runtime/host/backup.ex` | `connect/2` · `push/1` · `status/1` · `disconnect/1` |
| `Workbooks.AuthIntegrations` | `runtime/host/auth_integrations.ex` | `providers/0` · `identity_from_claims/1` · `config/0` |
| Git subtree/restore helpers | `runtime/host/git.ex` | `restore/3` · `copy_subtree/4` · `shareable_folders/1` · `backup_status/1` (extract this subset, not the whole module) |

**Shared dependencies the package must vendor or abstract:**
- `Workbooks.Git` — the per-tenant git store (extract the subtree/restore/log subset behind a small `Store` behaviour; leave Radicle/forge-provision out).
- `Workbooks.ControlPlane` — only the `shares` + `roles` tables and `workbook_tenant`/`workbook_visible?`/`role_of` are needed; abstract behind a `Registry` behaviour so adopters can back it with their own DB.
- `Workbooks.Tenant.visible?/2` — the one tenant-visibility rule (tiny, copy verbatim).

**HTTP contract (reference adapter):** the `/api/history/*`, `/api/nexuses/:id/drafts*`,
`/api/shared-folders/*`, `/api/roles`, `/api/nexuses/:id/backup*`, `/api/auth-integrations`
routes in `runtime/host/web.ex` are the canonical REST shape. Ship them as a Plug
router in the package so an adopter mounts one plug.

**Reference UI:** the dashboard components (`History.svelte`, `Drafts.svelte`,
`Shared folders`, the roles matrix) are the reference front-end — MIT, framework-light,
copyable.

## License — DECIDED: Apache-2.0 (founder, 2026-06-14)
**Apache-2.0** (matches `josh`/`jj`; patent grant; permissive enough for adoption).
The eventual standalone repo gets its own `LICENSE`; **do not** add a root `LICENSE`
to THIS repo — that would license the commercial runtime too. The package's `NOTICE`
should credit josh/jj as design prior art.

## Extraction plan (when greenlit)
1. New repo `workbooks-collab` (or a path-dep umbrella app here first).
2. Define `Store` + `Registry` behaviours; move the seven modules + the git subtree
   subset + `Tenant.visible?` behind them. Default impls: a plain git dir + SQLite
   (Exqlite) — no platform coupling.
3. Port the test suites (`history_test`, `draft_test`, `shared_folder_test`,
   `rbac_test`, `jj_undo_test`, `backup_integrations_test`) — they're already
   store-only, no network.
4. Add the Plug router + the Svelte reference components.
5. `Apache-2.0` + `NOTICE`; a README leading with the Drive-simple pitch.
6. Publish to Hex (`workbooks_collab`) + npm (the UI kit).

## Before you publish (irreversible — founder call)
- License is decided (**Apache-2.0**). Still to confirm at publish time: the exact
  **OSS-vs-commercial line** above (which modules ship) and the package/repo name.
- Audit the extracted code for any platform secret/coupling (there should be none —
  these modules are store + tenant only).
- A public release cannot be un-published; the name is effectively permanent. This
  doc is the staging ground; nothing here ships until the extraction is executed.
