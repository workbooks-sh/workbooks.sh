# Waldo in-chat components

The chat-rendering counterpart to the artifact/renderer system. Waldo (the
resident agent in the right-side chat) can answer in **org-mode**, and its org
can carry **inline components** it authors plus **tool-call** renderings.

This is the design + the slice-1 implementation. It reuses the existing
`$lib/org-renderer` OQL-WASM pipeline rather than introducing a second org
parser (golden rule: DRY, least code, componentize).

## Recon (where things live today)

- **Assistant text → DOM:** `desktop/src/lib/chat/ChatPanel.svelte:367`
  `<div class="agent-text">{b.text}</div>` — plain text, `white-space: pre-wrap`.
- **Message projection:** `desktop/src/lib/chat/session.svelte.ts` — channel
  events (`llm_turn_stop.metadata.content`) become `AssistantMessage.text`
  (`types.ts:59`). Tool calls become `ToolCallBlock` (`types.ts:74`), rendered as
  the collapsible `.tool-card` at `ChatPanel.svelte:375-421`.
- **Existing org renderer:** `desktop/src/lib/org-renderer/render.ts`
  `renderOrg(src)` → calls `oql.renderHtml(src)` (OQL WASM, `oql.ts`) + heading
  chrome transforms. `OrgView.svelte` drops the HTML with `{@html}`. CSS in
  `org.css`.
- **Waldo's system prompt:** `runtime/host/web.ex:855` `agent_system_prompt/1`
  (default Waldo string + per-slug `agents/<slug>.org` override parsed by
  `runtime/host/agent_def.ex` under the `** System prompt` heading).
- **Component conventions (org artifacts):** `toolkits/orgitorial/skills/components.org`
  — components are authored as `#+begin_src html …` / `#+begin_src mermaid` /
  `#+begin_src html :app` source blocks with header args. We mirror that style.
- **Design tokens:** `desktop/src/app.css:25-140` — `--color-fg`,
  `--color-surface`, `--color-border`, `--radius-md/sm`, `--color-accent`,
  `--color-err` (light + dark).

## Message format (chosen: per-message org flag, simplest that works)

A Waldo response is **either plain text (today's behavior, default) or a whole
org document**. We do **not** invent fenced "org regions" inside plain text —
that needs a second nested parser and a guessing heuristic. Instead a single
marker on the message selects the renderer:

- A message whose body **starts with the line `#+RENDER: org`** (a normal org
  keyword line, cheap for the LLM to emit) is rendered as org.
- Anything else renders exactly as before — plain `pre-wrap` text. **No
  regression.**

This is detected in one place (`renderMode(text)` in `messageRender.ts`) so the
contract has one home. Streaming-friendly: the marker is the first line, so the
decision is stable from the first delta.

## Inline-component contract

Inside an org message, a component is a source block:

```org
#+begin_src component :type callout :tone info
*Heads up* — the build finished in 4.2s.
#+end_src
```

- `:type` selects the Svelte renderer (slice-1 types: `callout`, `kv` table).
- Remaining header args (`:tone`, `:title`, …) are props.
- The **block body** is the payload. For `callout` it's a short line of text;
  for `kv` it's `key: value` lines (one per row). Bodies stay tiny and
  declarative — the component owns the visual.

Why a `component` src block (not `#+EXEC` or raw `html :app`): it matches the
orgitorial `#+begin_src <lang> :args` shape the project already teaches authors,
keeps the payload sandboxed (we never `{@html}` LLM output — components read
structured props), and is trivially extensible by adding a `:type` case.

## Render pipeline

```
AssistantMessage.text
  └─ renderMode()  →  "plain" | "org"
        plain →  <div class="agent-text">{text}</div>   (unchanged)
        org   →  splitOrg(text)  →  Segment[]
                    segment.kind="org"        →  renderOrg() → {@html}  (OQL WASM)
                    segment.kind="component"  →  <ChatComponent type props body/>
```

`splitOrg` slices the message on `#+begin_src component … #+end_src` boundaries.
Prose between/around the component blocks is rendered by the **existing**
`renderOrg()` (no new org parser). Component blocks are parsed into
`{type, props, body}` and dispatched to `ChatComponent.svelte`, which switches on
`type`. All chrome uses the app's `--color-*` tokens.

`AssistantMessageView.svelte` owns this; `ChatPanel.svelte` just renders it in
place of the old `<div class="agent-text">`.

## Tool calls (reuse, don't duplicate)

Tool calls already render as `.tool-card` from `ToolCallBlock`
(`session.svelte.ts` projection + `ChatPanel.svelte:375`). In-chat org components
are a property of the **message** block only; the tool-card path is untouched.
"Tool-call renderings inside org" are out of scope for slice 1 — if Waldo wants
to show a tool result visually it puts the data in a `component` block. The
existing tool-step UI remains the source of truth for live tool execution.

## Staged plan

- **Slice 1 (this change): org text rendering + inline components.**
  `messageRender.ts` (mode + split + parse), `ChatComponent.svelte` (callout +
  kv), `AssistantMessageView.svelte` (orchestration), wired into
  `ChatPanel.svelte` behind the `#+RENDER: org` marker. Plain messages
  unchanged.
- **Slice 2: richer component types** — `chart` (sparkline/bars from inline
  data), `card`, `table`. Add `:type` cases + the matching prop parsers; no
  pipeline change.
- **Slice 3: teach Waldo to emit org** — extend `agent_system_prompt/1`
  (`runtime/host/web.ex`) / Waldo's `agents/*.org` with the `#+RENDER: org`
  contract + the component catalog, so it opts into org when a visual answer
  helps. Runtime change, gated separately from this UI slice.
