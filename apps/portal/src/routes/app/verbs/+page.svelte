<script lang="ts">
  import { VERBS, groupByNamespace } from "@brandnana/schema/verbs";
  import type { Verb } from "@brandnana/schema/verbs";

  let filter = $state("");

  const METHOD_COLOR: Record<string, string> = {
    GET: "#4caf7d",
    POST: "#4a90d9",
    PATCH: "#d4900a",
    DELETE: "#c94040",
  };

  let filteredVerbs = $derived(
    filter.trim()
      ? VERBS.filter((v) => v.id.toLowerCase().includes(filter.trim().toLowerCase()))
      : VERBS,
  );

  let groups = $derived(groupByNamespace(filteredVerbs));

  function methodColor(method: string): string {
    return METHOD_COLOR[method] ?? "#a89070";
  }
</script>

<svelte:head>
  <title>Verbs — brandnana portal</title>
</svelte:head>

<div class="flex flex-col gap-4">
  <div class="flex flex-col gap-1 mb-2">
    <h1 class="font-serif text-base font-normal text-fg tracking-tight">verbs</h1>
    <p class="text-fg-muted text-xs">
      Every endpoint in the brandnana API. Click a verb for curl, CLI, SDK, and MCP snippets.
    </p>
    <input
      class="input mt-2 max-w-xs"
      type="text"
      placeholder="filter verbs…"
      bind:value={filter}
      aria-label="Filter verbs by id"
    />
  </div>

  {#if filteredVerbs.length === 0}
    <p class="text-fg-muted text-xs py-4">No verbs match <strong>{filter}</strong></p>
  {/if}

  {#each Object.entries(groups) as [ns, verbs]}
    <section class="flex flex-col gap-1 mb-6">
      <h2 class="text-fg-muted text-xs uppercase tracking-wider pb-2 border-b border-border-warm mb-1">{ns}</h2>
      <div class="flex flex-col gap-px">
        {#each verbs as verb (verb.id)}
          <a
            href="/app/verbs/{verb.id}"
            class="grid text-xs no-underline text-fg px-3 py-2.5 rounded-sm hover:bg-bg-cream transition-colors"
            style="grid-template-columns: 260px 1fr auto auto; gap: 1rem; align-items: center;"
          >
            <span class="font-mono text-fg font-medium whitespace-nowrap overflow-hidden text-ellipsis">{verb.id}</span>
            <span class="text-fg-muted whitespace-nowrap overflow-hidden text-ellipsis">{verb.summary}</span>
            <span class="font-mono text-xs font-bold uppercase tracking-wider whitespace-nowrap" style="color: {methodColor(verb.httpMethod)}">{verb.httpMethod}</span>
            <span class="font-mono text-xs text-fg-subtle whitespace-nowrap overflow-hidden text-ellipsis max-w-56">{verb.httpPath}</span>
          </a>
        {/each}
      </div>
    </section>
  {/each}
</div>
