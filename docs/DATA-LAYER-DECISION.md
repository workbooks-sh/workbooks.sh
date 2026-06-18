# Data Layer — the decision (inked)

North star: **Convex** — author the whole database in `.work`, little to no glue, it just
works. We don't copy it; we complete a model the literate format already started.

**Authoring vocabulary = WIT's own words.** What you author, what runs, and what you debug
are the same words — no translation layer. A stateful entity (a "table") is a WIT
**`resource`**; a pure value is a **`record`**; closed sets are **`enum`**; unions are
**`variant`**; operations are **`func`s**.

## The one-line architecture

> **One `resource` definition → the server gets an Ash database; the client gets the typed
> shape + WIT call-stubs; `wasmex` marshals every call; reactivity rides RCP-WS.**

Data is **server-authoritative** (the nexus). The client never runs a DB — it holds the
typed shape and *calls* the resource over WIT. One definition is the single source for both.

## Why `resource` — it aligns across every layer

| author writes | server (Ash) | wire contract (WIT) | debugger |
|---|---|---|---|
| `resource Lead` | **Ash resource** | **WIT `resource`** | same word |
| fields | attributes | the resource's `record` state | same |
| `query` / `mutation` | actions | `func` methods | same |
| `:new \| :scored` | `one_of` constraint | `enum` | same |
| `record Money` | embedded value | WIT `record` | same |

Ash *also* calls them resources. So one word — `resource` — runs author → engine → wire →
debug. No invented vocabulary, nothing to translate. WIT was already the contract; now it's
the language too.

## Layering (each tool has exactly one home)

| Layer | What | Runs where | Tool |
|---|---|---|---|
| **Literate surface** | `resource` / `record` / `enum` / `variant` (+ `query`/`mutation`) | authoring | **ours** |
| **Shape** | the typed struct the resource compiles to | client + server | **TypedStruct** (zero runtime deps → AtomVM-safe) |
| **Database** | persistence, reads, writes, validation, API | **server only** | **Ash** (resource = the table) |
| **Marshalling** | Elixir ↔ WIT across the wasm boundary | host↔guest | **wasmex.Components** |
| **Reactivity** | push query results to subscribed clients | server→client | **RCP-WS** (Ash notifications → WS) |

## The authoring vocabulary — the floor is just fields

```elixir
# A bare resource ALONE gives full CRUD + reactive reads. The common case is just the shape.
resource Lead do
  name     :text
  revenue  :money
  status   :new | :enriched | :scored      # enum, inline
  tags     [:text]                          # list
end
```

A pure value is a `record`, not a resource (no identity, no DB, no behavior):

```elixir
record Money do
  cents     :int
  currency  :usd | :eur | :gbp
end
```

Custom reads/writes live **inside** the resource, only when needed:

```elixir
resource Lead do
  name     :text
  revenue  :money
  status   :new | :enriched | :scored

  query :hot, where: status == :scored and revenue > 50_000
  mutation :enrich, do: ...                  # transactional
end
```

Compiles to: **Ash resource** (server: attributes + actions + data layer + validation),
**TypedStruct + WIT** (client: shape + call-stubs). Domain types (`:text`, `:money`, the
inline enum, `[:text]`) each map to one Ash attribute + one WIT type + one validator.

## What we reuse vs. write vs. delete

- **Reuse:** Ash (DB/actions/validation/API/backends), TypedStruct (client-safe shape),
  wasmex.Components (marshalling), RCP-WS (reactivity).
- **Write (the only new code):** the `resource → {TypedStruct, Ash resource, WIT}` compiler.
  It *reads declared types* — no inference.
- **Delete:** `Wit.Types` default-inference (the brittleness), the silent-`string`
  degradations in `wit.ex`, the hand-rolled binary protocol (`exec_broker`) for component
  units, the unvalidated `Jason.decode!` sites, `String.to_atom` risks.

## Hole-insurance (why a 17-dep framework is safe)

The literate surface sits **above** Ash. **Authors never see Ash's DSL** — they write
`resource`; we compile to Ash. The framework weight + Spark-DSL learning curve land on the
*compiler*, never the author. If Ash ever fights the model, we retarget the engine without
touching a single `.work` file.

## Build order (each step dogfooded on the demo Lead/Deal/Task)

1. **Shape** — `resource`/`record` macro → TypedStruct → sound WIT. Deletes `Wit.Types` inference.
2. **Database** — the same `resource` emits an Ash resource server-side; CRUD free.
3. **Calls** — client resource reference → WIT call-stub → wasmex → server Ash action.
4. **Reactivity** — Ash change-notifications → RCP-WS → the client view updates live.

## Evidence (spikes already run)

- **Ecto** introspection → faithful WIT + free changeset validation (~15-line deriver vs 76-line inference).
- **TypedStruct** compiles to a bare struct, runtime functions = `[__struct__]` only → AtomVM-safe.
- **wasmex.Components** marshals typed values across the boundary in our own `instance.ex` (no manual encode).
- **Ash** delivered CRUD + `one_of` enum validation + faithful WIT from one small resource
  (17 deps; ~3 iterations to learn conventions — friction lands on us, not authors).
