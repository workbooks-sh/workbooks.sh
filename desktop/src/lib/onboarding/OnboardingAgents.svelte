<script lang="ts">
  /**
   * OnboardingAgents — the "connect your agents" page that renders ABOVE the
   * coach (in the content area, centered + lifted) during the connect step.
   *
   * Workbooks runs the coding agents already on your machine (Claude Code, Codex,
   * Cursor) in isolated local microVMs. We DETECT them on PATH and, when you check
   * one, CONNECT it — which lights up the experimental `acp` toolkit for Waldo
   * (the runtime learns the connected agents via WB_ACP_AGENTS). Brand icons from
   * LobeHub (github.com/lobehub/lobe-icons).
   *
   * Detection + connect are REAL (Tauri connections_detect_local_cli /
   * connections_create_local_cli, wb-xiei.9). Claude Desktop has no CLI — it stays
   * a copy-the-MCP-command fallback. Graceful: outside Tauri / not found → the card
   * is disabled with the manual command.
   */
  import { CheckCircle, Copy, Circle, MagnifyingGlass } from "phosphor-svelte";
  import { onMount } from "svelte";
  import { fly, fade } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { invoke } from "@tauri-apps/api/core";
  import { connections } from "$lib/bridge/connections.svelte";
  import Icon from "$lib/ui/Icon.svelte";

  interface AgentTarget {
    id: string;
    name: string;
    icon: string; // lobe: brand slug
    binary: string | null; // CLI to detect on PATH (null = no CLI, manual only)
    service: string; // connection service id (matches the Rust conn store)
    where: string; // default hint when not yet detected
    command: string; // manual setup fallback (copied)
  }

  const AGENTS: AgentTarget[] = [
    { id: "claude-code", name: "Claude Code", icon: "lobe:claude-color", binary: "claude", service: "claude_code", where: "~/.claude", command: "npx skills add workbooks-sh/workbooks.sh" },
    { id: "codex", name: "Codex", icon: "lobe:openai", binary: "codex", service: "codex", where: "~/.codex", command: "npx skills add workbooks-sh/workbooks.sh" },
    { id: "cursor", name: "Cursor", icon: "lobe:cursor", binary: "cursor", service: "cursor", where: "~/.cursor", command: "cursor: add MCP — wb desktop mcp" },
    { id: "claude-desktop", name: "Claude Desktop", icon: "lobe:claude-color", binary: null, service: "claude_desktop", where: "app", command: "claude mcp add workbooks -- wb desktop mcp" },
  ];

  interface Probe { found: boolean; path: string | null; version: string | null; error: string | null }

  // Detection results (by id) + which services have a live connection.
  let probes = $state<Record<string, Probe>>({});
  let selected = $state<Record<string, boolean>>({});
  let busy = $state<Record<string, boolean>>({});

  const isDetected = (a: AgentTarget) => !!probes[a.id]?.found;
  const whereOf = (a: AgentTarget) => probes[a.id]?.path || a.where;
  const foundCount = $derived(AGENTS.filter(isDetected).length);

  async function toggle(a: AgentTarget) {
    if (!isDetected(a) || busy[a.id]) return;
    busy = { ...busy, [a.id]: true };
    try {
      if (selected[a.id]) {
        const c = connections.forService(a.service as never);
        if (c) await connections.disconnect(c.id);
        selected = { ...selected, [a.id]: false };
      } else {
        const p = probes[a.id];
        await invoke("connections_create_local_cli", {
          req: { service: a.service, path: p?.path ?? null, version: p?.version ?? null },
        });
        await connections.refresh();
        selected = { ...selected, [a.id]: true };
      }
    } catch { /* leave the prior state; the card reflects reality on next mount */ }
    finally { busy = { ...busy, [a.id]: false }; }
  }

  let copied = $state<string | null>(null);
  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      copied = text;
      setTimeout(() => (copied = null), 1600);
    } catch { /* selectable */ }
  }

  // `embedded` drops the standalone card chrome so this sits inside the coach.
  let { embedded = false }: { embedded?: boolean } = $props();

  // Scan-then-reveal: a brief "scanning" beat (the real PATH probe is fast) so
  // detection has a polished home, then reflect detected + already-connected.
  let scanning = $state(true);
  onMount(() => {
    let alive = true;
    void (async () => {
      try { await connections.refresh(); } catch { /* offline */ }
      const next: Record<string, Probe> = {};
      const sel: Record<string, boolean> = {};
      for (const a of AGENTS) {
        if (a.binary) {
          try {
            next[a.id] = await invoke<Probe>("connections_detect_local_cli", { name: a.binary });
          } catch {
            next[a.id] = { found: false, path: null, version: null, error: "not running in desktop" };
          }
        }
        if (connections.forService(a.service as never)) sel[a.id] = true;
      }
      if (!alive) return;
      probes = next;
      selected = sel;
    })();
    const t = setTimeout(() => { if (alive) scanning = false; }, 1300);
    return () => { alive = false; clearTimeout(t); };
  });
</script>

<div class="agents" class:embedded>
  <header>
    <h1>Connect your agents</h1>
    {#if scanning}
      <p in:fade={{ duration: 150 }}>Scanning your machine for installed agents…</p>
    {:else}
      <p in:fade={{ duration: 200 }}>Workbooks runs the coding agents already on your machine in isolated microVMs. We found
        <strong>{foundCount}</strong> — check the ones to connect; Waldo can then hand them tasks. Or copy the command.</p>
    {/if}
  </header>

  {#if scanning}
    <div class="scanning" out:fade={{ duration: 120 }}>
      <span class="radar"><MagnifyingGlass size={20} weight="bold" /></span>
      <div class="ghosts">
        {#each AGENTS as a, i (a.id)}
          <span class="ghost" style="animation-delay: {i * 160}ms"></span>
        {/each}
      </div>
    </div>
  {:else}
  <div class="grid">
    {#each AGENTS as a, i (a.id)}
      <button
        type="button"
        class="card"
        class:detected={isDetected(a)}
        class:sel={selected[a.id]}
        disabled={!isDetected(a) || busy[a.id]}
        aria-pressed={!!selected[a.id]}
        onclick={() => toggle(a)}
        in:fly={{ y: 12, duration: 300, delay: i * 80, easing: cubicOut }}
      >
        <span class="brand"><Icon value={a.icon} name={a.name} size={26} /></span>
        <span class="meta">
          <span class="name">{a.name}</span>
          <span class="where">{isDetected(a) ? whereOf(a) : "Not found"}</span>
        </span>
        <span class="state">
          {#if !isDetected(a)}
            <span class="copy-link" role="button" tabindex="0"
              onclick={(e) => { e.stopPropagation(); void copy(a.command); }}
              onkeydown={(e) => { if (e.key === "Enter") { e.stopPropagation(); void copy(a.command); } }}>
              {#if copied === a.command}<CheckCircle size={15} weight="fill" />{:else}<Copy size={14} weight="fill" />{/if}
            </span>
          {:else if selected[a.id]}
            <CheckCircle size={18} weight="fill" />
          {:else}
            <Circle size={18} weight="regular" />
          {/if}
        </span>
      </button>
    {/each}
  </div>
  {/if}

  <footer>
    <span class="hint">
      {scanning ? "Looking on your PATH + home configs…" : "Checked agents are connected now — Waldo runs them in isolated microVMs."}
    </span>
  </footer>
</div>

<style>
  .agents {
    width: min(520px, calc(100vw - 64px));
    pointer-events: auto;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 16px;
    box-shadow: var(--shadow-pop);
    padding: 22px 22px 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  /* Embedded in the coach — no card chrome; the coach is the card. */
  .agents.embedded {
    width: 100%;
    background: transparent;
    border: 0;
    box-shadow: none;
    padding: 0;
    gap: 12px;
  }
  header h1 {
    margin: 0 0 6px;
    font-size: 1.15rem;
    font-weight: 650;
    color: var(--color-fg);
  }
  header p {
    margin: 0;
    font-size: 0.86rem;
    line-height: 1.45;
    color: var(--color-fg-muted);
  }
  header strong { color: var(--color-fg); font-weight: 650; }
  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
  }

  /* Scanning beat — a pulsing radar + ghost chips spinning up. */
  .scanning {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 16px;
    padding: 14px 0 6px;
  }
  .radar {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 44px;
    height: 44px;
    border-radius: 50%;
    color: var(--color-brand);
    background: color-mix(in srgb, var(--color-brand) 10%, transparent);
    animation: radar-pulse 1.1s ease-in-out infinite;
  }
  .radar :global(svg) { animation: radar-spin 1.6s linear infinite; }
  .ghosts {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    width: 100%;
  }
  .ghost {
    height: 58px;
    border-radius: 12px;
    background: linear-gradient(
      100deg,
      var(--color-surface-soft) 30%,
      color-mix(in srgb, var(--color-fg) 6%, var(--color-surface-soft)) 50%,
      var(--color-surface-soft) 70%
    );
    background-size: 220% 100%;
    animation: ghost-shimmer 1.2s ease-in-out infinite;
  }
  @keyframes radar-pulse {
    0%, 100% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--color-brand) 28%, transparent); }
    50% { box-shadow: 0 0 0 8px color-mix(in srgb, var(--color-brand) 0%, transparent); }
  }
  @keyframes radar-spin { to { transform: rotate(360deg); } }
  @keyframes ghost-shimmer {
    0% { background-position: 180% 0; }
    100% { background-position: -80% 0; }
  }
  @media (prefers-reduced-motion: reduce) {
    .radar, .radar :global(svg), .ghost { animation: none; }
  }
  .card {
    display: flex;
    align-items: center;
    gap: 11px;
    padding: 11px 12px;
    border: 1px solid var(--color-border);
    border-radius: 12px;
    background: var(--color-surface-soft);
    cursor: pointer;
    text-align: left;
    transition: border-color 0.14s, background 0.14s, opacity 0.14s;
  }
  .card:not(.detected) { opacity: 0.6; cursor: default; }
  .card.detected:hover { border-color: var(--color-border-strong); }
  .card.sel {
    border-color: var(--color-brand);
    background: color-mix(in srgb, var(--color-brand) 8%, var(--color-surface));
  }
  .brand {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    flex-shrink: 0;
  }
  .brand :global(img) { display: block; }
  .meta { display: flex; flex-direction: column; min-width: 0; flex: 1 1 auto; }
  .name {
    font-size: 0.9rem;
    font-weight: 550;
    color: var(--color-fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .where {
    font-family: var(--font-mono);
    font-size: 0.68rem;
    color: var(--color-fg-subtle);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .state {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    color: var(--color-fg-subtle);
  }
  .card.sel .state { color: var(--color-brand); }
  .copy-link {
    display: inline-flex;
    padding: 4px;
    border-radius: 6px;
    color: var(--color-fg-subtle);
  }
  .copy-link:hover { background: color-mix(in srgb, var(--color-fg) 8%, transparent); color: var(--color-fg); }
  footer .hint {
    font-size: 0.76rem;
    color: var(--color-fg-subtle);
  }
</style>
