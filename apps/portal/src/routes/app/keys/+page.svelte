<!--
  API keys management. All data fetching + mutations are server-side via
  form actions. No client-side JWT plumbing. The keys list re-fetches via
  SvelteKit's invalidation after each successful action.
-->
<script lang="ts">
  import { enhance } from "$app/forms";
  import { invalidateAll } from "$app/navigation";
  import type { PageData, ActionData } from "./$types";

  let { data, form }: { data: PageData; form: ActionData } = $props();
  let busy = $state(false);
  let pendingRevoke = $state<string | null>(null);
  let newLabel = $state("");

  // Show the cleartext from the most recent create action exactly once.
  let dismissedKey = $state<string | null>(null);
  const showCleartext = $derived(form?.created?.cleartext && form.created.cleartext !== dismissedKey ? form.created.cleartext : null);

  function fmt(ts: number | null): string {
    if (!ts) return "—";
    return new Date(ts).toISOString().slice(0, 10);
  }
</script>

<svelte:head><title>keys · brandnana</title></svelte:head>

<div class="flex flex-col gap-5">
  <div class="flex flex-col gap-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">api keys</h2>
    <p class="text-fg-muted text-xs">
      Keys authenticate requests to <code class="font-mono bg-bg-cream border border-border-warm px-1 rounded-sm">api.brandnana.net</code>. Store secrets securely — they are shown once.
    </p>
  </div>

  {#if showCleartext}
    <div class="border border-warn px-3 py-3 flex flex-col gap-2 rounded-sm bg-bg-cream">
      <span class="warn text-xs font-mono">[!] copy this key now — it will not be shown again</span>
      <div class="flex items-center gap-3">
        <code class="font-mono text-xs text-fg break-all flex-1">{showCleartext}</code>
        <button class="btn" onclick={() => (dismissedKey = showCleartext)} type="button">[dismiss]</button>
      </div>
    </div>
  {/if}

  {#if form?.error}
    <p class="error text-xs">{form.error}</p>
  {/if}
  {#if data.loadError}
    <p class="error text-xs">{data.loadError}</p>
  {/if}

  <!-- Create form -->
  <form
    method="POST"
    action="?/create"
    use:enhance={() => {
      busy = true;
      return ({ update }) => update().then(() => (busy = false));
    }}
    class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-3"
  >
    <div class="section-title">new key</div>
    <div class="flex gap-2">
      <input
        type="text"
        name="label"
        bind:value={newLabel}
        class="input flex-1 max-w-xs"
        placeholder="label (e.g. production, ci)"
        maxlength={64}
      />
      <button type="submit" class="btn" disabled={busy}>[+ create]</button>
    </div>
  </form>

  <!-- Key list -->
  {#if data.keys.length === 0}
    <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
      <span class="muted">no api keys yet</span>
      <p class="subtle">create one above to get started.</p>
    </div>
  {:else}
    <div class="border border-border-warm rounded-sm overflow-hidden">
      <table>
        <thead>
          <tr>
            <th>label</th>
            <th>key</th>
            <th>created</th>
            <th>last used</th>
            <th>actions</th>
          </tr>
        </thead>
        <tbody>
          {#each data.keys as key (key.id)}
            <tr>
              <td>{key.label ?? "—"}</td>
              <td>
                <code class="font-mono subtle text-xs">
                  {key.prefix}…{key.revoked_at ? " (revoked)" : ""}
                </code>
              </td>
              <td class="muted">{fmt(key.created_at)}</td>
              <td class="muted">{fmt(key.last_used_at)}</td>
              <td>
                {#if !key.revoked_at}
                  <form
                    method="POST"
                    action="?/revoke"
                    use:enhance={() => {
                      busy = true;
                      return ({ update }) => update().then(() => (busy = false));
                    }}
                    class="inline"
                  >
                    <input type="hidden" name="id" value={key.id} />
                    {#if pendingRevoke === key.id}
                      <button type="submit" class="btn warn" disabled={busy}>[confirm revoke]</button>
                    {:else}
                      <button
                        type="button"
                        class="btn"
                        onclick={() => (pendingRevoke = key.id)}
                        disabled={busy}
                      >
                        [revoke]
                      </button>
                    {/if}
                  </form>
                {/if}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<style>
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #e5e5e5; }
  th { font-weight: 500; color: #555; background: #fafafa; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
  td.muted { color: #666; }
  .subtle { color: #666; }
  .muted { color: #666; }
  .warn { color: #c00; }
  .error { color: #c00; }
  .section-title { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: #555; }
  .btn { background: white; border: 1px solid #e5e5e5; padding: 4px 8px; border-radius: 4px; cursor: pointer; font-family: inherit; font-size: 11px; }
  .btn:hover { background: #f8f8f8; }
  .btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .input { padding: 6px 10px; border: 1px solid #e5e5e5; border-radius: 4px; font-size: 12px; }
</style>
