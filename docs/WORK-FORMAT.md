# The work-* component model

One consistent way to author everything in a workbook — tasks, agents, flows,
loops, prompts, data, docs — as `work-*` web components. **The artifact is plain
HTML.** There is no separate text format, no shorthand, no parser, no kernel:
a workbook is an HTML file that uses the `work-*` custom elements from the
`workponents/` Lit library, and the browser renders it.

## Decisions (locked)

1. **A workbook IS an HTML file.** `.html`, double-clickable, opens in any
   browser, web-native. `work-*` custom elements *are* valid HTML, so the
   structure lives directly in the document — no separate, non-browser file type.
2. **One mechanism.** Everything is `element + attributes + nesting + prose`. No
   special syntaxes per concept. Keep the verb/primitive count tiny; consolidate;
   stay composable.
3. **No text format.** There is no `.work` shorthand and no format spec to parse.
   The `work-*` library (a Lit web-component library we own, in `workponents/`)
   IS the model. Authoring is HTML; rendering is the browser + those components.
4. **Org-mode is fully retired.** It lives only in git history. We kept org's
   good *ideas* (status, tags, structured properties, dates, build edges, tables)
   — re-expressed as plain attributes on `work-*` elements — and dropped org's
   syntax, parser, and kernel entirely.
5. **Single structural truth = `work-*` elements.** Where the backend must read a
   workbook's STRUCTURE (the compiler finding `<work-component>` source to build;
   validation; an outline), it parses the HTML with a STANDARD parser — Floki in
   Elixir (`Workbooks.Workbook`), a small standard scanner in the Rust CLI /
   desktop shell — never a custom engine.

## The element model

A `work-*` element is just an HTML element: a tag, attributes, nested children,
and a text body (prose the component renders). Org's special fields are plain
attributes now:

| Org idea | Now |
|---|---|
| TODO/DONE state | `status="todo"` |
| `:tags:` | `tag="urgent"` / `@name` sugar |
| `:PROPERTIES:` drawer | plain attributes |
| `SCHEDULED`/`DEADLINE` | `due=` / date attributes (see Time) |
| outline nesting | element nesting |
| `#+begin_src` + header args | `<work-component lang= in= out= deps= dir=>` |
| tables | `<work-table>` |

Backend structure-reading (`Workbooks.Workbook` over Floki) maps the parsed
element tree to the same row/plan shapes downstream logic (tangle/build-plan,
validate) already consumed — it reads HTML attributes, never org syntax.

## Authoring

```html
<work-sprint title="Sprint 24" start="2026-06-15" end="2026-06-29">
  <work-task title="Ship the renderer" status="todo" assignee="kai" due="2026-06-22" estimate="3d">
    Needs the data layer first. **Blocks** the demo.
  </work-task>
  <work-task title="Wire the board" status="done"></work-task>
</work-sprint>
```

That HTML is the source of truth. No projection, no expansion step.

## Rendering

Rendering is the browser plus the `work-*` Lit components. Each `work-*` element
renders its own attributes in its shadow DOM — status pills, tag chips, property
drawers are component behavior, not post-hoc regex injection. The backend's
"render of a workbook" is the HTML itself (passthrough): `Workbooks.Workbook.render/1`
returns the workbook's HTML; the visual render happens client-side.

## Data: SQL in HTML

Declarative data sources are `work-*` elements; view components read from them by
name. The same tag works over SQLite *or* Postgres — the host decides where the
query actually runs (embedded SQLite-wasm when static, native exqlite when docked,
a real Postgres connection in a nexus). This rides the existing Host capability
seam (the Dock membrane); the author writes intent, not a driver.

```html
<work-query name="big-orders" db="sales" sql="select * from orders where total > 100"></work-query>
<work-table from="big-orders"></work-table>
<work-chart from="big-orders"></work-chart>
```

Verb budget: one source element + a `from=` binding. No per-database tags.

## Time

Time is first-class, because it is the easy thing to get subtly wrong.

**Principle — "now" is injected, never read.** Components and the host do date
math on values they are given; the current instant comes from the host, never a
guest system call. This keeps rendering deterministic and replay/resume-safe.

**Representations (all plain attribute strings):**

- **Instant** — ISO-8601, timezone-aware: `due="2026-06-22"`, `at="2026-06-22T10:00Z"`.
- **Duration / span** — human shorthand normalized to ISO-8601:
  `estimate="3d"` → `P3D`, `duration="2h30m"` → `PT2H30M`.
- **Interval** — `start=` + `end=`.
- **Recurrence** — `cron="0 9 * * 1"` for jobs; `repeat="weekly"` for simple
  cadences (normalized to RRULE).

**Triggering is the host's job.** The runtime's existing cron/scheduler computes
*when* things fire and fires them; the components describe schedules declaratively.

## The structural vocabulary

`work-*` config-island elements: PM (`work-task`, `work-board`, `work-sprint`,
`work-milestone`), agentic (`work-flow`, `work-loop`, `work-agent`, `work-system`),
data (`work-query` + `from=` bindings), and the buildable `<work-component>` (its
`lang`/`in`/`out`/`deps`/`dir` attributes + text body feed the compiler lane).
The component registry (CEM) is the schema the structure validates against.
