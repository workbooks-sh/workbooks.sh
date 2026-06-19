# ctk — authoring a story (component + Org control-spec)
0.1.0
Use when adding a new CTK story. The render(el,props) contract, the Controls table schema, and the :tangle source block — the shell stays fixed.

# When to use this
NETWORK: no
DESTRUCTIVE: no
COST: free

  Use when you have a component to put on the bench. You write two things — a
  `render` function and an Org control-spec — and the standard shell does the
  rest. NOT for changing the shell itself (the shell is the standard; don't fork
  it per story).

# The contract — two pieces

## 1. The render contract

  The stage hosts any module that exports:

```js
  export function render(el, props) { /* paint el from props; called on every change */ }
```

  - `el` is a fresh mount node; `props` is the live control state.
  - Re-render must be idempotent (set `el.innerHTML` or reconcile). The shell
    calls `render` on first paint and on every control change.
  - Plain JS today; the same contract is what a Svelte/Solid/WASM build targets
    (it's the polyglot seam — compile to a module exposing `render`).

## 2. The Org control-spec

  One Org node carrying a `Controls` table + the source in a `:tangle` block:

```org
  ,* Component
    :PROPERTIES:
    :NAME: MyThing
    :END:

  ,** Controls
    | prop   | type   | default | range/options |
    |--------+--------+---------+---------------|
    | label  | text   | Hello   |               |
    | hue    | range  | 200     | 0..360        |
    | filled | toggle | true    |               |
    | shape  | select | round   | round|square  |

  ,** States
  ,*** default
  ,*** disabled
      :OVERRIDE: disabled:true
      | prop    | type  | default | range/options |
      |---------+-------+---------+---------------|
      | opacity | range | 0.55    | 0..1:0.05     |
  ,*** loading
      :OVERRIDE: loading:true

  ,** Source
    ,#+begin_src js :tangle component.js
    export function render(el, props) { ... }
    ,#+end_src
```

  Controls schema (the SHARED props — apply to every state):
  - `prop` — must match a key read in `render`.
  - `type` — `text` | `color` | `range` | `toggle` | `select`.
  - `default` — seeds the prop (coerced by type: range→number, toggle→bool).
  - `range/options` — `min..max` (optionally `min..max:step`) for range; `a|b|c`
    for select; blank otherwise.

  States schema (optional — omit the section if the component has no conditions):
  - Each `*** <name>` headline is a state; it renders as its own cell on the
    stage, *side-by-side* with the others. The first headline is the base/default.
  - `:OVERRIDE:` (optional) — comma-separated `key:value` props applied for that
    state (`disabled:true`). Values coerce: true/false→bool, numeric→number.
  - An optional controls table under the headline = that state's PER-STATE
    controls: props you can tune for THAT cell only (e.g. the disabled state's
    `opacity`). Same columns as `Controls`.

  *Props vs States — the rule that prevents the disabled-button confusion:*
  - A *prop* is a value a consumer authors (`label`, `variant`, `color`, `size`).
    It belongs in `Controls` (shared, left panel).
  - A *state* is a condition the component can be in (`default`, `disabled`,
    `loading`, `error`). It belongs in `States` — rendered side-by-side, not
    tuned. Give a state its own controls only when something about THAT state is
    worth tuning (the disabled opacity); otherwise it just shows on the stage.

# Workflow

  1. Write `render(el, props)` for your component (plain JS, or build a
     framework component down to a module exposing `render`).
  2. Author the Org node: `:NAME:`, a `Controls` table, and the source in a
     `:tangle component.js` block.
  3. Embed it: today, drop the Org into `ctk.html`'s `<script id`"ctk-spec"
     type="text/org">= block. (Milestone 2: stories load as separate files and
     the runtime mounts them.)
  4. `open ctk.html` and tune.

# Common pitfalls

  1. *Prop/control name drift* — a row whose `prop` no key in `render` reads is a
     dead control. Keep names identical.
  2. *Non-idempotent render* — appending instead of replacing makes the stage
     accrete duplicates on each change. Set/replace, don't append.
  3. *Indented tangle block* — the shell strips a 2-space org indent; deeper or
     tab indentation can corrupt the imported JS. Keep the block at one consistent
     indent.
  4. *Self-mounting components* — if the module renders to `document.body` or its
     own root instead of the passed `el`, nothing shows on the stage.

# Verification checklist

  - [ ] Component exports `render(el, props)`.
  - [ ] Every `Controls` row's `prop` is read in `render`.
  - [ ] `open ctk.html` shows it; each control re-renders live.
  - [ ] Editing the `:tangle` block changes the rendered output (tangle works).

# See also

  - [overview](overview.md) — what CTK is and the shell.
  - `../ctk.html` — the reference shell + FolderIcon story to copy from.
