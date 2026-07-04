# Workbooks Cloud — Data surface, fully-featured plan

> **Airtable-easy for the non-technical, Supabase-powerful for those who want it** — and dogfooded:
> a "table" is a **`.work` resource**, so it comes with a typed API, validation, and access rules for
> free. That's the wedge — our tables aren't dumb grids, they're typed resources you author *visually*.

## 1. Audience & the two modes

Most users never write SQL. So the surface is **visual-first**, SQL-optional:

- **Visual mode** (default): create tables by naming fields + picking types; browse/edit rows in a grid
  or a form; filter/sort/group with menus; import a CSV. Zero jargon. This is the Airtable experience.
- **SQL mode** (opt-in): a read-only SQL editor with saved, named **snippets** — for people who want it.

The same data, two doors. Nobody is forced through the SQL door.

## 2. The object model (mapped to our stack — no fiction)

| Surface concept | What it really is |
|---|---|
| **Table** | a `resource :name do field … end` block in a workbook (Nexus.Resource) |
| **Field + type** | a typed `field` (text/number/date/bool/select/link/file) → validation + the API shape |
| **Row** | a Store row `(id, tenant, data)`, tenant-partitioned (SQLite → Litestream → S3) |
| **View** | a saved filter/sort/column-set over a table (metadata, not a copy) |
| **Snippet** | a saved, named, re-runnable query (read-only SQL) — see §6 |
| **Auto-API** | the resource already compiles to a typed REST/client API — free per table |

**Creating a table = authoring a resource.** The visual builder writes a `.work` `resource` block (dogfood:
everything is a workbook). So a new table instantly has: a typed schema, validation, an auto-generated
API, and client+server access — things Airtable can't give you.

## 3. What "fully featured" means (the real-expectation checklist)

**Tables & schema**
- Create table visually (name + fields + friendly types). ✳ *prototyped in the demo*
- Field types: Text, Long text, Number, Date/Time, Checkbox, Single-select, Multi-select, **Link to
  another table** (relationship), Attachment/File, Email, URL, JSON.
- Edit schema: add / rename / retype / reorder / delete a field; delete a table (with guardrails).
- Sensible defaults + required/unique toggles per field.

**Rows (data)**
- Grid browse with pagination + virtualized scroll for big tables. ✳ *demo grid exists*
- Add / edit / delete a row — inline in the grid **and** via a form (non-technical). ✳ *add-row prototyped*
- Bulk: multi-select → delete/duplicate/edit; undo.
- Cell editing per type (date picker, select dropdown, checkbox, file upload, linked-record picker).

**Find & shape**
- **Filters** (field ops), **sorts** (multi), **column show/hide/reorder**, **group by**.
- **Saved views** (each a named filter/sort/column set); a default view per table.
- **Search** across a table (and, later, across all tables).

**Relationships**
- Link fields → foreign keys; **lookup** fields (pull a value from a linked row); simple rollups (count/sum).

**Import / export**
- **CSV import** → creates a table (infers types) or appends to one. Export a table/view to CSV/JSON.

**SQL & snippets** (§6)
- Read-only SQL editor; **saved snippets** (named, parameterized, re-runnable); query history.

**Charts**
- Quick chart from a table or query (bar/line/pie/number), droppable onto Overview.

**API & realtime**
- Every table auto-exposes a typed API (already true of resources); show the endpoints + a copy-curl.
- Live updates in the grid (the store is the reactive seam).

**Governance**
- Per-table read/write permissions by role (owner/admin/member/viewer).
- **History**: row-level change history + point-in-time restore (Litestream already gives us the WAL
  timeline — surface it as "restore this table to 3pm yesterday").

## 4. The hard prerequisites (found while building — real, not optional)

The visual UI is ready to prototype; the *live* surface needs, in order:

1. **Resource registry** — enumerate a workspace's tables. Nothing does today (`Store.all` needs a named
   module). **Blocks everything.**
2. **Per-tenant read path** — the Data surface queries the tenant's **own nexus** read-only, never the
   multi-tenant control-plane db (which holds `pw_hash` + secrets). Cross-org isolation by construction.
3. **JSON codec** — resource rows are `:erlang.term_to_binary` blobs today; storing them as JSON text
   turns on real field-level SQL + filters (SQLite `json1`). One codec change + a migration.
4. **Visual builder → `.work` writer** — the create-table modal must emit a real `resource` block into a
   workbook (and schema edits patch it). This is what makes a "table" a typed resource, not a raw table.

## 5. Build order (phased, each shippable)

- **P0 — Foundation:** resource registry + per-tenant read path + JSON codec.
- **P1 — Visual tables:** create-table → writes a `resource` block; grid browse (decoded rows); add/edit/
  delete rows (grid + form). *The Airtable core.*
- **P2 — Shape:** filters, sorts, hide/reorder columns, saved views, search, CSV import/export.
- **P3 — SQL:** read-only editor + snippets (save/name/parameterize/history).
- **P4 — Relationships & charts:** link/lookup/rollup fields; quick charts.
- **P5 — Governance:** per-table permissions; row history + point-in-time restore; the auto-API panel;
  realtime grid.

## 6. Snippets = one shell, many runners (the concept from the earlier question)

A snippet is *a saved, named, re-runnable unit*. The **UX shell is identical everywhere** — `list + New ·
editor · Run · result` — and only two things swap by context: the **editor** (SQL vs `.work` code) and the
**result renderer** (grid vs output/log). Build it once here (SQL snippets), reuse it for a future
**Scripts/Actions** surface where the runner is `.work` code. Extensions: **parameters**
(`where id = :contact`), **save/share** in the workspace, **history** (last run / who). Scheduling is a
separate "jobs" concept so snippets stay interactive.

## 7. Open decisions

1. **JSON codec** now (real SQL + filters) or keep blobs (browse-only) until later?
2. **Read-only** first, or **read/write** (edit rows) from the start? *(Rec: read/write via the visual
   form + validated through the resource schema — writes are safe because the resource validates them.)*
3. Create-table writes a **`.work` resource** (dogfood, typed API for free) vs a raw table? *(Rec: the
   resource — it's the whole advantage.)*
4. Where do **Scripts/Actions** live (the non-SQL snippet runner) — inside Data, or their own surface?
