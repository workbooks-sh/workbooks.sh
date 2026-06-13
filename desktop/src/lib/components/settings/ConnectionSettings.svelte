<script lang="ts">
  /**
   * ConnectionSettings (wb-aakl.6) — the Connection tab.
   *
   * The full-surface companion to the titlebar NexusPopover (wb-aakl.9):
   * same `nexus` store, more room. Lists every connectable nexus with
   * live health, lets the user switch the active one, and add/remove
   * remotes. The Local entry is zero-config (reads daemon discovery) and
   * cannot be removed.
   */
  import { Planet, Plus, Trash as Trash2, ArrowClockwise, CheckCircle } from "phosphor-svelte";
  import { nexus, type NexusEndpoint, type NexusHealth } from "$lib/bridge/nexus.svelte";

  let adding = $state(false);
  let fName = $state("");
  let fUrl = $state("");
  let fToken = $state("");

  $effect(() => {
    nexus.probeAll();
  });

  function submitAdd(e: Event) {
    e.preventDefault();
    const url = fUrl.trim();
    if (!url) return;
    const id = nexus.add({ name: fName, url, token: fToken });
    nexus.select(id);
    fName = fUrl = fToken = "";
    adding = false;
  }

  function dotClass(h: NexusHealth): string {
    return h === "ok" ? "ok" : h === "checking" ? "checking" : h === "down" ? "down" : "unknown";
  }
  function healthLabel(h: NexusHealth): string {
    return h === "ok" ? "connected" : h === "checking" ? "checking…" : h === "down" ? "unreachable" : "unknown";
  }
  function urlFor(ep: NexusEndpoint): string {
    if (ep.mode === "local") return nexus.activeUrl && ep.id === nexus.activeId ? nexus.activeUrl : "auto-discovered";
    return ep.url;
  }
</script>

<div class="connection">
  <header class="head">
    <div class="kicker"><Planet weight="fill" size={12} /> Nexus</div>
    <button type="button" class="icon-btn" title="Re-check health" onclick={() => nexus.probeAll()}>
      <ArrowClockwise weight="bold" size={12} />
    </button>
  </header>
  <p class="lede">
    A nexus is a runtime this browser talks to. <b>Local</b> is found
    automatically; add a remote nexus to connect to a hosted or team runtime.
  </p>

  <div class="list">
    {#each nexus.endpoints as ep (ep.id)}
      {@const h = nexus.healthOf(ep.id)}
      {@const isActive = ep.id === nexus.activeId}
      <div class="ncard" class:active={isActive}>
        <button type="button" class="ncard-main" onclick={() => nexus.select(ep.id)}>
          <span class="dot {dotClass(h)}" class:alive={h === "ok"}></span>
          <span class="ntext">
            <span class="nrow">
              <span class="nname">{ep.name}</span>
              {#if ep.mode === "local"}<span class="tag">local</span>{/if}
            </span>
            <span class="nurl">{urlFor(ep)}</span>
          </span>
          <span class="nstate">
            {#if isActive}<CheckCircle weight="fill" size={14} class="active-tick" />{/if}
            <span class="hlabel">{healthLabel(h)}</span>
          </span>
        </button>
        {#if ep.mode === "remote"}
          <button type="button" class="icon-btn danger" title="Remove nexus" onclick={() => nexus.remove(ep.id)}>
            <Trash2 weight="fill" size={12} />
          </button>
        {/if}
      </div>
    {/each}
  </div>

  {#if adding}
    <form class="add-form" onsubmit={submitAdd}>
      <label>
        <span class="flabel">Name</span>
        <input bind:value={fName} placeholder="Team runtime" spellcheck="false" />
      </label>
      <label>
        <span class="flabel">URL</span>
        <input bind:value={fUrl} placeholder="https://nexus.example.com:4000" spellcheck="false" autocomplete="off" />
      </label>
      <label>
        <span class="flabel">Token <span class="opt">optional</span></span>
        <input bind:value={fToken} type="password" placeholder="Bearer token" spellcheck="false" autocomplete="off" />
      </label>
      <div class="add-actions">
        <button type="button" class="ghost" onclick={() => (adding = false)}>Cancel</button>
        <button type="submit" class="primary" disabled={!fUrl.trim()}>Connect</button>
      </div>
    </form>
  {:else}
    <button type="button" class="add-row" onclick={() => (adding = true)}>
      <Plus weight="bold" size={13} /> Add a nexus
    </button>
  {/if}
</div>

<style>
  .connection {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
    max-width: 640px;
  }
  .head { display: flex; align-items: center; justify-content: space-between; }
  .kicker {
    display: flex;
    align-items: center;
    gap: 7px;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--color-brand);
  }
  .lede {
    margin: 0;
    font-size: 13px;
    line-height: 1.55;
    color: var(--color-fg-muted);
  }
  .lede b { color: var(--color-fg); font-weight: 600; }
  .list { display: flex; flex-direction: column; gap: 8px; }
  .ncard {
    display: flex;
    align-items: center;
    gap: 6px;
    border: 1px solid var(--color-border);
    border-radius: 12px;
    background: var(--color-surface);
    transition: border-color 0.15s;
  }
  .ncard.active { border-color: var(--color-brand); box-shadow: inset 0 0 0 1px var(--color-brand); }
  .ncard-main {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 14px;
    border: 0;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    text-align: left;
    border-radius: 12px;
  }
  .ncard-main:hover { background: color-mix(in srgb, var(--color-fg) 4%, transparent); }
  .ncard.active .ncard-main:hover { background: transparent; }
  .dot { width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0; background: var(--color-fg-subtle); }
  .dot.ok { background: var(--color-ok); }
  .dot.down { background: var(--color-err); }
  .dot.checking { background: var(--color-warn); }
  .ntext { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }
  .nrow { display: flex; align-items: center; gap: 8px; }
  .nname { font-size: 13.5px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tag {
    font-family: var(--font-mono);
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    padding: 1px 6px;
    border-radius: 999px;
  }
  .nurl {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg-subtle);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .nstate { display: flex; align-items: center; gap: 7px; flex-shrink: 0; }
  .nstate :global(.active-tick) { color: var(--color-brand); }
  .hlabel { font-family: var(--font-mono); font-size: 10.5px; color: var(--color-fg-subtle); }
  .icon-btn {
    display: grid;
    place-items: center;
    width: 30px;
    height: 30px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
    flex-shrink: 0;
    margin-right: 6px;
  }
  .head .icon-btn { margin-right: 0; }
  .icon-btn:hover { background: color-mix(in srgb, var(--color-fg) 6%, transparent); color: var(--color-fg); }
  .icon-btn.danger:hover { color: var(--color-err); }
  .add-row {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    align-self: flex-start;
    padding: 9px 14px;
    border: 1px dashed var(--color-border-strong);
    border-radius: 10px;
    background: transparent;
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
  }
  .add-row:hover { color: var(--color-fg); border-color: var(--color-fg-subtle); }
  .add-form {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 14px;
    border: 1px solid var(--color-border);
    border-radius: 12px;
    background: var(--color-surface);
  }
  .add-form label { display: flex; flex-direction: column; gap: 5px; }
  .flabel {
    font-family: var(--font-mono);
    font-size: 10.5px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }
  .flabel .opt { font-weight: 400; text-transform: none; letter-spacing: 0; color: var(--color-fg-subtle); }
  .add-form input {
    padding: 9px 12px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
    color: var(--color-fg);
    font-family: var(--font-mono);
    font-size: 12.5px;
  }
  .add-form input:focus { outline: none; border-color: var(--color-ring); }
  .add-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 2px; }
  .ghost, .primary {
    padding: 9px 16px;
    border-radius: 9px;
    border: 0;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
  }
  .ghost { background: transparent; color: var(--color-fg-muted); }
  .ghost:hover { color: var(--color-fg); }
  .primary { background: var(--color-fg); color: var(--color-page); }
  .primary:disabled { opacity: 0.45; cursor: default; }
</style>
