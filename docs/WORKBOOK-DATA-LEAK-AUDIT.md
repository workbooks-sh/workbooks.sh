# Workbook Data-Leak Audit — Embedded VFS on Egress

READ-ONLY security fact-check. Concern: standardizing workponents data components on
querying a workbook's embedded SQLite VFS could leak data when the `.html` is
served / downloaded / published, because the VFS travels with the file.

Ground truth from the code (file:line cited). **No code was changed.**

---

## (A) What actually gets embedded / served

There are **two distinct egress mechanisms** with **different privacy postures**. The
worry assumes a single "the VFS travels with the file" path; the reality is split.

### A1. `Bundle.ship/4` — the VFS-volume embed path (privacy-enforced)

`runtime/host/bundle.ex:315` `ship(id, html, vfs_bytes, opts)` is the only path that
embeds **SQLite VFS volume bytes** into a workbook.

- `bundle.ex:319` — **strips private volumes by default**:
  `vfs_bytes = if opts[:include_private], do: vfs_bytes, else: Workbooks.VFS.public_only(vfs_bytes)`
- `vfs.ex:69` `public_only/1` opens the SQLite bytes and runs
  `DELETE FROM vfs WHERE volume NOT IN ('workspace')` then `VACUUM`
  (`vfs.ex:73-76`). `keep` = `Workbooks.Private.public_volumes/0` = `["workspace"]`
  (`private.ex:35,38`).
- So by default **only the `workspace` volume ships**; **`memory` (agent long-term
  memory) and `tmp` (scratch) are deleted** before embed.
- The manifest records the truth: `"volumes" => Workbooks.Private.public_volumes()`
  and `"private_included" => false` unless opted in (`bundle.ex:324-326`).
- Opt-in to ship everything is explicit and loud: `include_private: true`
  (`bundle.ex:319,324`), the same flag `Library.pack` exposes via `purpose: :archive`
  (`library.ex:202`).

**Verdict: the dedicated VFS-egress path is safe-by-default — `memory`/`tmp` do NOT
travel; only `workspace` does.** This is the single boundary module
`Workbooks.Private` (`private.ex:1-70`), consulted by Git, Bundle, and Library so the
rule can't drift between egresses.

### A2. CLI / RCP `bundle` — the file-tree embed path (no SQLite VFS at all)

The everyday "build a single-file workbook" path does **not** embed any SQLite VFS
volume. It embeds a **directory tree of files**:

- CLI `bundle` (`cli.ex:268-286`): `Bundle.read_tree(dir) |> tangle_files |> compile_tree`,
  then `pack` + `embed`. `read_tree/1` (`bundle.ex:201-211`) walks the dir and
  **rejects private/session files** via `strip_path?/1` (`bundle.ex:233-238`), which
  consults the `@strip_segments` denylist (`.git`, `.beads`, `.claude`, `node_modules`,
  `_build`, `.tmp`, `.private` — `bundle.ex:36-37`) **and** `Workbooks.Private.private?/1`
  (telemetry sidecars `_steps.jsonl`/`_status.json`/`_trace.jsonl`, `scratch/`, `.drafts/`,
  and the VFS private-volume dirs `memory/`/`tmp/` — `private.ex:24-48`).
- The embedded blob here is the **working tree's files** (org source, tangled native,
  compiled `.wasm`, `index.html`), not a SQLite database. There is no `vfs.sqlite`
  entry in this path.

**Verdict: the CLI/RCP build path also strips session/private files; it carries the
working tree, not the session.**

### A3. The PUBLIC serve plane embeds **no VFS at all**

`Workbooks.PublicWeb.serve/1` (`public_web.ex:193-207`) resolves the host → app and
either serves static files from `build/public/<app>/` (`public_web.ex:215-233`) or
renders the stored org via `static_page/2` (`public_web.ex:322-333`).

- `static_page/2` returns either the author's complete HTML verbatim, or
  `static_doc(id, org)` via the orgitorial renderer (`public_web.ex:273-388`) — a **rendered org → HTML
  doc**. It injects only `Bundle.loader_block()` (`public_web.ex:385`), the hydration
  JS, **not any VFS bundle**.
- `Publish.render/2` (the `work publish` path, `publish.ex:90-97`) is the same:
  `PublicWeb.static_page(title, org)` → HTML file. No VFS embed.

So on the **public content plane**, the served bytes are the rendered page + loader.
A VFS only appears in a served file if the author themselves bundled one into the
`.html` they uploaded (via A1/A2, which already strip private volumes). The plane is
also anonymous, GET-only, no Dock, no secret access by design (`public_web.ex:8-20`),
with a defense-in-depth CSP that treats embedded bundle bytes as inert data
(`public_web.ex:276-286`).

### Summary table

| Egress | Embeds SQLite VFS? | `memory`/`tmp` stripped? | Mechanism |
|---|---|---|---|
| `Bundle.ship` (share/sign, store/3 archive) | Yes (`workspace` only by default) | Yes — `public_only` `DELETE` + `VACUUM` (`vfs.ex:69-82`) | safe-by-default |
| CLI/RCP `bundle` (single-file build) | No — file tree only | Yes — `read_tree` strips (`bundle.ex:233-238`) | safe-by-default |
| Public serve / `work publish` | No | n/a (no VFS) | rendered org only |
| RCP `/rcp/bundle` (desktop passthrough) | Whatever caller ships | **No server-side strip** — see D1 | caller-controlled |

---

## (B) Confirmed-safe vs leak vectors (with evidence)

### Confirmed safe

1. **`memory`/`tmp` volumes never embed by default** — `vfs.ex:69-82` + `bundle.ex:319`.
   The whole `public_only` step + the `Workbooks.Private` boundary exist precisely for
   this (`private.ex:1-22` documents the "beads pushed to GitHub" leak class that
   motivated it).
2. **Secrets / credentials never live in the VFS.** The secret store is a separate
   SQLite db (`Vars`, `vars.ex:37` `WB_VARS`/`:memory:`), not the workbook VFS.
   - `Vars.get/2` redacts secret values to `{:secret, :redacted, byte_size}` —
     plaintext never returned to a guest (`vars.ex:48-57`).
   - `Vars.ref/3` leaves `{{secret:KEY}}` placeholders intact for `:guest` mode and
     resolves them only in `:host` mode at egress, outside the guest's reach
     (`vars.ex:64-79`, doc `vars.ex:26-31`). An agent references a secret without ever
     holding its bytes.
   - The LLM key is held host-side; the `llm-complete` Dock import closes over it and
     the component never sees it (`instance/imports.ex:40-42`).
   - The durable k/v `StorageBroker` is server-side and tenant-scoped; it is not the
     workbook VFS and is never embedded (`storage_broker.ex:5-12`).
   - The public plane has **no secret-access route** at all (`public_web.ex:11-13`).
   **Confirmed: creds stay host-side and do not travel in a served workbook.**
3. **Sealed entries (`gated:`) are ciphertext, key escrowed host-side.** Even when an
   entry is embedded, `seal_gated` AES-256-GCMs it; the manifest carries only a
   `key_refs` reference, never the key (`bundle.ex:293-307,380-387`,
   `bundle/escrow.ex:4`). The key is released only after `Workbooks.Access.enforce`
   passes.
4. **Tenant isolation on the durable store** — every `wb_kv` row is `tenant`-scoped and
   the tenant is supplied by the host/Dock, never the guest (`storage_broker.ex:7-9`,
   `:171-178`).
5. **Docked `vfs-query` is scoped to the one instance's VFS connection** — the import
   closes over that instance's `vfs_conn` (`instance/imports.ex:33-34`,
   `instance.ex:39,91-92`). One workbook cannot reach another's VFS via the Dock.
6. **Public plane is read-only and isolated** — no `Auth` plug, GET-only, no Dock, no
   build/agents/secret routes (`public_web.ex:8-20`); path-traversal-contained
   (`public_web.ex:215-303`).
7. **Provenance binds the embedded payload** — a signed embedded `.html` must carry a
   `wb.bundle.sha256` assertion matching the actual blob, else `verify/1` fails closed
   (`bundle.ex:619-634`). Tamper-evident, though note this is *integrity*, not
   *confidentiality* (see C).

### Leak vectors (ranked)

**[HIGH] LV-1 — `/rcp/bundle` performs NO server-side privacy strip.**
`web.ex:943-966` packs exactly the `files` the caller ships, derives the page, embeds,
optionally signs — with **no** `Workbooks.Private.strip_parts` and **no**
`VFS.public_only`. If a desktop/CLI client ships a parts map that includes a full
`vfs.sqlite` (all volumes) or `memory/`/`tmp/` files, the engine embeds them verbatim.
The privacy guarantee here lives entirely in the *client*, not the engine. This is the
one egress that does NOT consult the shared boundary. Severity high because it is a
tenant-authenticated egress that can produce a downloadable `.html`. (See D1.)

**[MEDIUM] LV-2 — author writes sensitive app data into the `workspace` volume.**
`workspace` is, by contract, PUBLIC-to-the-recipient (it ships in every default
egress: `public_only` keeps it, `read_tree` keeps it). The proposed standard's default
data source is the workbook VFS. An author who does
`INSERT INTO vfs(volume,...) VALUES('workspace', ...)` with private rows (PII, internal
metrics, customer data) ships that data to every recipient of the file. The system
behaves exactly as designed — the surprise is purely a mental-model gap. This is the
central risk the workponents standard must guard against. (See C + D2.)

**[MEDIUM] LV-3 — `Library.query` cross-member query-through is in-tenant only, but
returns every member's VFS rows to the caller.**
`Library.query/2` → `vfs_query/2` (`library.ex:125-149`) runs one SQL across **every**
workspace member's VFS and returns rows tagged by member. `members/1` and
`workspaces/1` are scoped to `Git.repo_path(tenant)` (`library.ex:23-39`), and `access`
returns `"none"` for any non-owner identity (`library.ex:47-52`), so this does **not**
cross tenants. The exposure is *within one tenant's own Library*: a query-through reads
the `workspace` volume of every member (and `memory`/`tmp` too if a member bundle was
archived with `include_private`). Not a cross-tenant leak, but the standard should note
that query-through widens the blast radius of LV-2 across a whole workspace.

**[LOW] LV-4 — `vfs-query` exposes the `volume` column / all volumes of the live
instance.**
`query_json/2` runs arbitrary read SQL against the whole `vfs` table including `memory`
and `tmp` (`vfs.ex:89-97`, schema `vfs.ex:22-28`). A component can `SELECT * FROM vfs`
and read its own agent memory / scratch at runtime. This is intra-instance (the
component already runs as that instance) so it is not a cross-boundary leak — but a
data component that naively does `SELECT * FROM vfs` and renders it could surface
`memory`/`tmp` content into the page DOM at runtime. Defensive default: components
should scope queries to `WHERE volume='workspace'`, not `SELECT * FROM vfs`.

**[LOW] LV-5 — `public_only` is best-effort and rescues to the ORIGINAL bytes on
error.**
`vfs.ex:80-81`: `rescue _ -> bytes`. If the SQLite open/DELETE/VACUUM fails for any
reason, `public_only` returns the **un-stripped** original bytes (all volumes). A
corrupt or unusual SQLite blob could thus ship `memory`/`tmp` despite the default. Fail
posture should arguably be fail-closed (return empty / raise), not fail-open. Low
severity because it requires a SQLite error, but it silently defeats the headline
guarantee.

**[LOW] LV-6 — `VACUUM` does not guarantee secure erasure of deleted page content.**
`public_only` does `DELETE ... VACUUM` (`vfs.ex:74-75`). `VACUUM` rebuilds the db so
freelist pages are normally reclaimed, but it is not a cryptographic wipe and depends
on SQLite internals; there is no overwrite/secure-delete pragma. For the threat model
(don't ship `memory`/`tmp`) `VACUUM` is adequate in practice, but it is worth noting it
is not a hard guarantee that no deleted-volume bytes remain in the rebuilt file.

---

## (C) Safe data-standard defaults + guardrails

The framing in the prompt is **correct and validated by the code**:

> VFS = container/content + processing scratch — **it travels with the file, so treat
> the shipping volume (`workspace`) as PUBLIC-to-the-recipient.** Durable / sensitive
> app data belongs in Postgres / an external backend (server-side, NOT embedded,
> reached only when docked).

The code already encodes the volume contract: `workspace` ships, `memory`/`tmp` stay
home (`private.ex:34-38`, `vfs.ex:69-82`). The standard should make the *consequence*
explicit to authors.

Recommended defaults for the workponents data standard:

1. **The default source for a data component must be an explicit, named volume — and
   the only embed-eligible volume is `workspace`, which is PUBLIC-to-recipient.**
   Document `workspace` as "travels with the file." Never let a component default to
   `SELECT * FROM vfs` (that pulls `memory`/`tmp` — LV-4).
2. **Sensitive / durable / multi-user data defaults to a named Postgres/external
   backend (server-side), reached only when docked.** Never embedded. This is the safe
   home for PII, customer data, anything not meant for the recipient. The Host already
   routes `(b) named Postgres/external` server-side; make that the documented default
   for any component declared as holding private/durable data.
3. **A volume-travel contract surfaced in the component API.** Each data source
   declares its volume; the standard states plainly: writing to `workspace` (or any
   embedded volume) = publishing that row to everyone who gets the file. `memory`/`tmp`
   are never embed targets for app data.
4. **Lint / warn at author time** when a component's default source resolves to an
   embedded volume AND the workbook is being shipped/published — "this data will travel
   with the file." Especially warn when a query reads `memory`/`tmp` or omits a
   `volume` filter (LV-4). This is the single highest-leverage guardrail against LV-2.
5. **Secrets never in any VFS volume.** Authors must use `{{secret:KEY}}` via `Vars`
   (`vars.ex:26-31`) and host-side resolution; the standard should forbid persisting
   tokens/keys into `workspace` (or any volume). The platform already keeps creds out
   of the VFS; the standard must not reintroduce them.
6. **`/rcp/bundle` must enforce the same boundary as every other egress** (fix LV-1):
   apply `Workbooks.Private.strip_parts` + `VFS.public_only` server-side unless
   `include_private` is explicitly set, so the engine never trusts the client to have
   done the strip.
7. **Note query-through blast radius** (LV-3): a `Library.query` data component reads
   the `workspace` volume of *every* member in the workspace; treat it as a
   workspace-wide read, not a single-workbook read.

---

## (D) Active-leak bugs to file

### D1 — `/rcp/bundle` egress has no server-side private-data strip  [HIGH]
**File:** `runtime/host/web.ex:943-966`.
The route packs the caller's `files` map verbatim (`web.ex:949-951`), derives the page,
embeds, optionally signs — with no `Workbooks.Private.strip_parts` and no
`VFS.public_only`. Every other egress (`Bundle.ship` `bundle.ex:319`, CLI `bundle`
`cli.ex:279` via `read_tree`, `Library.pack` `library.ex:233`) consults the shared
`Workbooks.Private` boundary; this one does not. A tenant client that ships a
`vfs.sqlite` with all volumes, or `memory/`/`tmp/` tree files, gets them embedded into a
downloadable, optionally-signed `.html`. Recommend: route the parts through
`Workbooks.Private.strip_parts` (and `VFS.public_only` for any `vfs.sqlite` entry)
unless an explicit `include_private=1` query param is set. **Do not fix in this audit —
file as a bug.**

### D2 — `public_only/1` fails OPEN on error  [LOW]
**File:** `runtime/host/vfs.ex:80-81` (`rescue _ -> bytes`).
On any SQLite error during the strip, the function returns the **original, un-stripped**
bytes (all volumes, incl. `memory`/`tmp`), silently defeating the default privacy
guarantee. Recommend fail-closed (raise, or return an empty-but-valid db) so a strip
failure never degrades to shipping the full session. **File as a hardening bug.**

### D3 — (advisory, not a bug) `VACUUM` is not secure erasure  [LOW]
**File:** `runtime/host/vfs.ex:74-75`. Adequate for the current threat model; documented
here so it is not mistaken for a cryptographic wipe.

---

## Bottom line

The platform's **dedicated** egress paths (`Bundle.ship`, CLI/RCP `bundle` via
`read_tree`, `Library.pack`) are **safe-by-default**: `memory`/`tmp` are stripped, only
`workspace` travels, secrets never enter the VFS, and tenant isolation holds. The
proposed workponents framing (VFS = public-to-recipient container/scratch; durable
sensitive data in server-side Postgres/external) is **correct** and matches the code's
volume contract.

The real risks are (1) one egress route that skips the shared boundary (**D1/LV-1,
file it**), (2) the author-mental-model gap that `workspace` data ships to recipients
(**LV-2**, the standard must make this loud + lint it), and (3) a fail-open strip
(**D2/LV-5**). None of these are cross-tenant leaks; the isolation boundaries
(`tenant`-scoped Library/StorageBroker, per-instance Dock VFS, anonymous read-only
public plane) hold.
