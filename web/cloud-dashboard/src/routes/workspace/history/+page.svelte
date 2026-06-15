<script>
  import History from '$lib/History.svelte';
  import { workspaceStore } from '$lib/workspaceStore.svelte.js';

  // History + Restore for the active workspace. Reuses the shared History panel
  // (api.js → /api/history/:scope); returns [] honestly until a runtime is wired.
  const ws = $derived(workspaceStore.active);
  const scope = $derived(ws?.id || null);
</script>

{#if scope}
  <History {scope} />
{:else}
  <div class="card faint" style="text-align:center">No workspace selected.</div>
{/if}
