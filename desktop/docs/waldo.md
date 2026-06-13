# Waldo — the resident browser agent (wb-aakl.21)

The browser ships with exactly **one** built-in agent: Waldo. Not a Claude
Code replacement — a resident communicator you summon to set up and work the
system. Waldo is the autopoet (wb-9ae) surfaced as the browser's
orchestration/communicator layer. The multi-agent chat chrome (agent
picker, per-session model picker, agent CRUD) stays flagged off
(WB_FF_AGENTS); Waldo replaces it with a single voice.

**Pitch guard:** Waldo is a communicator you summon, never a self-running
site manager.

## Surface (shipped)

- A first-party **dock panel** (`WaldoPanel.svelte`), registered **always**
  in the extension dock (wb-aakl.14) — not flag-gated. Icon top-right;
  toggles open like any dock panel.
- Text chat over the salvaged `chatSession` transport, targeting the
  `waldo` agent slug. Composer + a time-ordered transcript (user echoes +
  Waldo's response blocks, with compact tool/status lines).
- A no-key / no-nexus explainer state that tells the user how to wake Waldo
  (connect a nexus + add an OpenRouter key or Gemini voice).

## Capabilities (can / can't)

Waldo **can**: answer questions; work within the workspace; run search (the
composable providers, wb-aakl.19); open/manage tabs; read engine state +
logs to debug natively; take notes; and — its specialty — **find issues**
in systems and work them, filing issues for itself via the autopoet
`file_issue` seam, editing only the declarative layer (toolkits/skills/
defs), never host code (autopoet canon).

Waldo **can't**: edit host/native code; act without being summoned; replace
Claude Code for heavy build work. It's the in-browser communicator and
issue-finder, not an autonomous builder.

## Access paths

- **Text** — an OpenRouter key (via the keychain keys store).
- **Voice** — the Gemini Live connection (the same wiring HomePanel uses).
  Either unlocks Waldo; absent both, the panel explains how to add one.

## Extensible

Waldo's tools come from the Browser SDK (wb-aakl.15) + toolkits — the same
membrane any dock panel uses. "Write your own agent for the browser" is
literally this: a dock panel using the SDK. Waldo is the first-party
instance.

## Agent-to-agent (Claude Code ↔ Waldo)

The embedded MCP (wb-aakl.11 / server in wb-aakl.23) exposes `waldo_ask` and
`waldo_do` so Claude Code can converse with Waldo directly — Claude Code
asks a question or hands off a task; Waldo answers or acts in the browser.

## Status

- ✅ Resident dock panel (text transcript + composer, no-key state),
  registered always; brand canon; lazy-loaded (excluded from entry chunk).
- ⏳ The runtime brain → **wb-aakl.25**: the `waldo` agent definition in the
  runtime config layer, the autopoet `file_issue` seam (wb-9ae phase 1),
  voice wiring (lift HomePanel's geminiLive callbacks), and the MCP
  `waldo_ask`/`waldo_do` tools (joins wb-aakl.23). These need the runtime
  build/run loop + on-device verification, not available in the autoloop.
