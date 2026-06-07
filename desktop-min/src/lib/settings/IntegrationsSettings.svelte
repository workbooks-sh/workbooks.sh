<script lang="ts">
  /**
   * IntegrationsSettings — connected services. Each catalog service is
   * a card: connect (managed OAuth) when absent, disconnect when
   * present. Connection kind shows as a chip. Secrets/env vars are a
   * separate surface, deferred with the backend.
   */
  import { onMount } from "svelte";
  import { Boxes, Link2, Unlink } from "@lucide/svelte";
  import { commands, type ConnectionRedacted } from "$lib/bindings";
  import SettingsPanel from "./SettingsPanel.svelte";

  // Static catalog — the services the agent can connect to.
  const catalog = ["GitHub", "Claude Code", "Composio", "Doppler", "Slack", "Linear"];

  let connections = $state<ConnectionRedacted[]>([]);

  onMount(async () => {
    connections = await commands.connectionsList();
  });

  function find(service: string) {
    return connections.find((c) => c.service === service);
  }

  const kindLabel: Record<ConnectionRedacted["kind"], string> = {
    managed_oauth: "OAuth",
    local_cli: "Local CLI",
    api_key: "API key",
  };

  async function connect(service: string) {
    const created = await commands.connectionsCreate({ service, kind: "managed_oauth" });
    connections = [...connections, created];
  }

  async function disconnect(c: ConnectionRedacted) {
    await commands.connectionsDelete(c.id);
    connections = connections.filter((x) => x.id !== c.id);
  }
</script>

<SettingsPanel title="Integrations" lede="Connect services so the agent can act on them. Connecting installs the matching skill.">
  <div class="grid">
    {#each catalog as service (service)}
      {@const conn = find(service)}
      <article class="card" class:on={conn}>
        <span class="ico"><Boxes size={16} strokeWidth={1.7} /></span>
        <span class="body">
          <span class="name">{service}</span>
          <span class="state">
            {#if conn}
              <span class="dot ok"></span> Connected
              <span class="chip">{kindLabel[conn.kind]}{conn.version ? ` · ${conn.version}` : ""}</span>
            {:else}
              <span class="dot idle"></span> Not connected
            {/if}
          </span>
        </span>
        {#if conn}
          <button class="btn ghost" onclick={() => disconnect(conn)}>
            <Unlink size={12} strokeWidth={1.8} /> Disconnect
          </button>
        {:else}
          <button class="btn primary" onclick={() => connect(service)}>
            <Link2 size={12} strokeWidth={1.8} /> Connect
          </button>
        {/if}
      </article>
    {/each}
  </div>
</SettingsPanel>

<style>
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 0.5rem;
  }
  .card {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.6rem 0.7rem;
    border: 1px solid var(--color-border);
    border-radius: 10px;
    background: var(--color-surface);
  }
  .card.on {
    border-color: var(--color-border-strong);
  }
  .ico {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    flex-shrink: 0;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
  }
  .body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
  }
  .name {
    font-size: 0.84rem;
    font-weight: 600;
  }
  .state {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    font-size: 0.7rem;
    color: var(--color-fg-muted);
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .dot.ok {
    background: var(--color-ok);
  }
  .dot.idle {
    background: var(--color-fg-subtle);
  }
  .chip {
    padding: 0.05em 0.4em;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    font-size: 0.62rem;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    flex-shrink: 0;
    height: 26px;
    padding: 0 0.55rem;
    border-radius: 7px;
    border: 1px solid transparent;
    font: inherit;
    font-size: 0.72rem;
    font-weight: 500;
    cursor: pointer;
  }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover {
    color: var(--color-fg);
  }
</style>
