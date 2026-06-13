<script lang="ts">
  /**
   * NexusPopover (wb-aakl.9) — anchored to the titlebar engine chip.
   *
   * Lists the connectable nexuses (runtimes): the zero-config `Local`
   * entry (live from the daemon discovery) plus any saved remotes. Click
   * a row to make it active — every RCP call follows. "Add nexus" takes a
   * name + URL + optional token. Health dots: local mirrors the sidecar
   * probe, remotes are probed via /health.
   */
  import { Planet, Plus, Trash as Trash2, X, ArrowClockwise } from "phosphor-svelte";
  import { nexus, type NexusEndpoint, type NexusHealth } from "$lib/bridge/nexus.svelte";

  let {
    anchor,
    open = $bindable(false),
  }: {
    anchor: HTMLElement | null;
    open: boolean;
  } = $props();

  let popoverEl: HTMLDivElement | undefined = $state();
  let adding = $state(false);
  let fName = $state("");
  let fUrl = $state("");
  let fToken = $state("");

  // Probe remotes whenever the popover opens.
  $effect(() => {
    if (open) nexus.probeAll();
  });

  function select(ep: NexusEndpoint) {
    nexus.select(ep.id);
  }

  function submitAdd(e: Event) {
    e.preventDefault();
    const url = fUrl.trim();
    if (!url) return;
    const id = nexus.add({ name: fName, url, token: fToken });
    nexus.select(id);
    fName = fUrl = fToken = "";
    adding = false;
  }

  function onDocClick(e: MouseEvent) {
    if (!open) return;
    const t = e.target as Node;
    if (popoverEl && popoverEl.contains(t)) return;
    if (anchor && anchor.contains(t)) return;
    open = false;
  }
  function onKey(e: KeyboardEvent) {
    if (open && e.key === "Escape") open = false;
  }

  function dotClass(h: NexusHealth): string {
    return h === "ok" ? "ok" : h === "checking" ? "checking" : h === "down" ? "down" : "unknown";
  }

  // Below + right-aligned to the chip (chip sits top-right).
  let style = $derived.by(() => {
    if (!anchor) return "";
    const r = anchor.getBoundingClientRect();
    const top = Math.round(r.bottom + 6);
    const right = Math.max(8, Math.round(window.innerWidth - r.right));
    return `top: ${top}px; right: ${right}px;`;
  });
</script>

<svelte:window onmousedown={onDocClick} onkeydown={onKey} />

{#if open}
  <div class="popover" bind:this={popoverEl} role="dialog" aria-label="Nexus" {style}>
    <header class="head">
      <Planet weight="fill" size={13} />
      <span class="title">Nexus</span>
      <span class="spacer"></span>
      <button type="button" class="icon-btn" title="Re-check health" onclick={() => nexus.probeAll()}>
        <ArrowClockwise weight="bold" size={11} />
      </button>
    </header>

    <div class="list">
      {#each nexus.endpoints as ep (ep.id)}
        {@const h = nexus.healthOf(ep.id)}
        <div class="row" class:active={ep.id === nexus.activeId}>
          <button type="button" class="row-main" onclick={() => select(ep)}>
            <span class="dot {dotClass(h)}" class:alive={h === "ok"}></span>
            <span class="row-text">
              <span class="name">{ep.name}</span>
              <span class="url">
                {ep.mode === "local" ? (nexus.activeUrl && ep.id === nexus.activeId ? nexus.activeUrl : "discovery") : ep.url}
              </span>
            </span>
            {#if ep.id === nexus.activeId}<span class="badge">active</span>{/if}
          </button>
          {#if ep.mode === "remote"}
            <button type="button" class="icon-btn danger" title="Remove" onclick={() => nexus.remove(ep.id)}>
              <Trash2 weight="fill" size={11} />
            </button>
          {/if}
        </div>
      {/each}
    </div>

    {#if adding}
      <form class="add-form" onsubmit={submitAdd}>
        <input bind:value={fName} placeholder="Name (optional)" spellcheck="false" />
        <input bind:value={fUrl} placeholder="https://nexus.example.com:4000" spellcheck="false" autocomplete="off" />
        <input bind:value={fToken} type="password" placeholder="Token (optional)" spellcheck="false" autocomplete="off" />
        <div class="add-actions">
          <button type="button" class="ghost-sm" onclick={() => (adding = false)}>
            <X weight="bold" size={11} /> Cancel
          </button>
          <button type="submit" class="primary-sm" disabled={!fUrl.trim()}>Connect</button>
        </div>
      </form>
    {:else}
      <button type="button" class="add-row" onclick={() => (adding = true)}>
        <Plus weight="bold" size={12} /> Add a nexus
      </button>
    {/if}
  </div>
{/if}

<style>
  .popover {
    position: fixed;
    z-index: 1000;
    width: 290px;
    background: color-mix(in srgb, var(--color-surface) 88%, transparent);
    backdrop-filter: blur(14px);
    border: 1px solid var(--color-border-strong);
    border-radius: 14px;
    box-shadow: var(--shadow-pop);
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 4px 6px 6px;
    color: var(--color-brand);
  }
  .head .title {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--color-fg);
  }
  .spacer { flex: 1; }
  .list { display: flex; flex-direction: column; gap: 2px; }
  .row {
    display: flex;
    align-items: center;
    gap: 4px;
    border-radius: 9px;
  }
  .row.active { background: var(--color-brand-soft); }
  .row-main {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 8px 10px;
    border: 0;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    text-align: left;
    border-radius: 9px;
  }
  .row-main:hover { background: color-mix(in srgb, var(--color-fg) 5%, transparent); }
  .row.active .row-main:hover { background: transparent; }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    background: var(--color-fg-subtle);
  }
  .dot.ok { background: var(--color-ok); }
  .dot.down { background: var(--color-err); }
  .dot.checking { background: var(--color-warn); }
  .row-text { display: flex; flex-direction: column; gap: 1px; min-width: 0; flex: 1; }
  .name { font-size: 12.5px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .url {
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--color-fg-subtle);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .badge {
    font-family: var(--font-mono);
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--color-brand);
    flex-shrink: 0;
  }
  .icon-btn {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border: 0;
    border-radius: 7px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
    flex-shrink: 0;
  }
  .icon-btn:hover { background: color-mix(in srgb, var(--color-fg) 6%, transparent); color: var(--color-fg); }
  .icon-btn.danger:hover { color: var(--color-err); }
  .add-row {
    display: flex;
    align-items: center;
    gap: 7px;
    width: 100%;
    padding: 8px 10px;
    border: 0;
    border-radius: 9px;
    background: transparent;
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 500;
    cursor: pointer;
  }
  .add-row:hover { background: color-mix(in srgb, var(--color-fg) 5%, transparent); color: var(--color-fg); }
  .add-form { display: flex; flex-direction: column; gap: 6px; padding: 6px; }
  .add-form input {
    padding: 7px 10px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
    color: var(--color-fg);
    font-family: var(--font-mono);
    font-size: 11.5px;
  }
  .add-form input:focus { outline: none; border-color: var(--color-ring); }
  .add-actions { display: flex; justify-content: flex-end; gap: 6px; }
  .ghost-sm, .primary-sm {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 6px 12px;
    border-radius: 8px;
    border: 0;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 500;
    cursor: pointer;
  }
  .ghost-sm { background: transparent; color: var(--color-fg-muted); }
  .ghost-sm:hover { color: var(--color-fg); }
  .primary-sm { background: var(--color-fg); color: var(--color-page); }
  .primary-sm:disabled { opacity: 0.45; cursor: default; }
</style>
