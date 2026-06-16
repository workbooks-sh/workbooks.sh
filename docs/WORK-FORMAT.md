# The Work Format

One consistent way to author everything in a workbook — tasks, agents, flows,
loops, prompts, data, docs — as `work-*` web components. The artifact is plain
HTML. Org-mode is retired.

## Decisions (locked)

1. **The file is HTML.** A workbook is a `.html` file: double-clickable, opens
   in any browser, web-native. `work-*` custom elements *are* valid HTML, so the
   structure lives directly in the document — no separate, non-browser file type.
2. **One mechanism.** Everything is `element + values + nesting + prose`. No
   special syntaxes per concept. Keep the verb/primitive count tiny; consolidate;
   stay composable.
3. **Optional shorthand.** A terse, indentation-based authoring view (extension
   `.work`) expands 1:1 into the HTML — a convenience, never the shipped artifact
   and never required. Same lineage as Pug/Slim/Haml: a projection of the element
   tree with no document model of its own.
4. **Org-mode is fully retired.** Nobody depends on it; there is no legacy
   contract to preserve. We keep org's good *ideas* (status, tags, structured
   properties, dates, build edges, tables) — re-expressed as plain attributes on
   `work-*` elements — and drop org's syntax entirely.
5. **Single structural truth = `work-*` components.** The kernel renders the
   node tree to `work-*` HTML; `bundle_islands.ex` already round-trips that form
   losslessly. No competing structure.

## The node model

The kernel parses any front-end into one generic tree:

```rust
struct Node {
    tag: String,                     // "work-task", "work-flow", ...
    attrs: BTreeMap<String, String>, // status=todo, due=2026-06-22, title=...
    body: String,                    // prose (the component renders markdown)
    children: Vec<Node>,
}
```

Org's special fields collapse into attributes:

| Org idea | Now |
|---|---|
| TODO/DONE state | `status="todo"` |
| `:tags:` | `tag="urgent"` / `@name` sugar |
| `:PROPERTIES:` drawer | plain attributes |
| `SCHEDULED`/`DEADLINE` | `due=` / date attributes (see Time) |
| outline nesting | element nesting |
| `#+begin_src` + header args | `work-component` with `lang=`, `in=`, `out=`, `deps=` |
| tables | `work-table` (exists) |

All downstream logic (tangle/build-plan, validate, upgrade-gate) reads `Node`
fields — it never knew about org syntax and does not now.

## The shorthand grammar (`.work` → Node tree → HTML)

```
work-sprint "Sprint 24" start=2026-06-15 end=2026-06-29
  work-task "Ship the parser" status=todo @kai due=2026-06-22 estimate=3d
    Needs the renderer first. **Blocks** the demo.
  work-task "Wire the board" status=done
```

Rules (the whole grammar):

- indentation = child element — the **only** structural rule
- bare leading token = element tag → `<work-…>`
- first `"quoted string"` = `title` attribute / default slot
- `key=val` = attribute
- `@name` = value-primitive sugar → `assignee="name"` (small, documented sugar set)
- any non-element line = prose body (the component renders markdown)

This expands deterministically to the HTML form; the HTML is the source of truth.

## Rendering

`render()` walks the `Node` tree and emits `<work-{tag} ...attrs>` with children
and body — replacing the old `orgize.to_html()` path and the desktop
`transforms.ts` regex chrome. Status pills, tag chips and property drawers are no
longer post-hoc regex injection; each `work-*` element renders its own attributes
in its shadow DOM.

## Data: SQL in HTML

Declarative data sources are `work-*` elements; view components read from them by
name. The same tag works over SQLite *or* Postgres — the host decides where the
query actually runs (embedded SQLite-wasm when static, native exqlite when docked,
a real Postgres connection in a nexus). This rides the existing Host capability
seam (the Dock membrane); the author writes intent, not a driver.

```
work-query name="big-orders" db="sales" sql="select * from orders where total > 100"
work-table from="big-orders"
work-chart from="big-orders"
```

Verb budget: one source element + a `from=` binding. No per-database tags.

## Time

Time is first-class and explicitly designed, because it is the easy thing to get
subtly wrong (especially in WASM, where the guest has no clock).

**Principle — "now" is injected, never read.** The kernel does *pure* date math
on values it is given; the current instant always comes from the host
(`host_now`), never from a guest system call. This keeps rendering deterministic
and replay/resume-safe, matching how the rest of the sandbox treats the clock.

**Representations (all plain attribute strings):**

- **Instant** — ISO-8601, timezone-aware: `due="2026-06-22"`, `at="2026-06-22T10:00Z"`.
- **Duration / span** — human shorthand normalized to ISO-8601:
  `estimate="3d"` → `P3D`, `duration="2h30m"` → `PT2H30M`.
- **Interval** — `start=` + `end=`.
- **Recurrence** — `cron="0 9 * * 1"` for jobs; `repeat="weekly"` for simple
  cadences (normalized to RRULE).

**Computation — a small pure time library in the kernel (Rust):**

- add a duration to an instant; diff two instants → duration
- expand a recurrence; compute next cron fire-time relative to an injected `now`
- roll-ups (e.g. sum of child `estimate`s) for `work-task`/`work-flow`

**Triggering is the host's job.** The kernel computes *when* things fire; the
runtime's existing cron/scheduler actually fires them. The kernel never sleeps,
never reads the clock, never triggers.

## Workstreams

1. **Node model + shorthand parser + renderer** (kernel foundation). Generic
   `Node`, the `.work` parser, the tree → `work-*` HTML emitter.
2. **Rewire downstream** — tangle/validate/upgrade read `Node` attrs/tags instead
   of org tags + header-args; drop orgize and the desktop `transforms.ts` regex.
3. **`work-*` structural vocabulary** — add config-island elements: PM
   (`work-task`, `work-board`, `work-sprint`, `work-milestone`), agentic
   (`work-flow`, `work-loop`; `work-agent`/`work-system` exist). Register in CEM +
   registry; the registry is the schema the format validates against.
4. **Data elements** — `work-query` + `from=` bindings over the SQLite/Postgres
   provider seam.
5. **Time library** — the pure date-math module + the host `now` injection point.

Source of truth for status: this doc + the bd epic. The artifact is always HTML.
