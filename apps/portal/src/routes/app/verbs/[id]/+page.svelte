<script lang="ts">
  import CodeBlock from "$lib/components/CodeBlock.svelte";
  import { curlSnippet } from "$lib/snippets/curl.js";
  import { cliSnippet } from "$lib/snippets/cli.js";
  import { sdkSnippet } from "$lib/snippets/sdk.js";
  import { mcpSnippet } from "$lib/snippets/mcp.js";
  import type { PageData } from "./$types";

  let { data }: { data: PageData } = $props();
  let { verb } = $derived(data);

  type Tab = "curl" | "cli" | "sdk" | "mcp";
  let activeTab = $state<Tab>("curl");

  const METHOD_COLOR: Record<string, string> = {
    GET: "#4caf7d",
    POST: "#4a90d9",
    PATCH: "#d4900a",
    DELETE: "#c94040",
  };

  let snippetContent = $derived(
    activeTab === "curl"
      ? curlSnippet(verb)
      : activeTab === "cli"
        ? cliSnippet(verb)
        : activeTab === "sdk"
          ? sdkSnippet(verb)
          : mcpSnippet(verb),
  );

  let snippetLang = $derived(
    activeTab === "curl"
      ? "bash"
      : activeTab === "cli"
        ? "bash"
        : activeTab === "sdk"
          ? "typescript"
          : "json",
  );

  function methodColor(method: string): string {
    return METHOD_COLOR[method] ?? "#a89070";
  }

  const tabs: { id: Tab; label: string }[] = [
    { id: "curl", label: "curl" },
    { id: "cli", label: "cli" },
    { id: "sdk", label: "sdk" },
    { id: "mcp", label: "mcp" },
  ];
</script>

<svelte:head>
  <title>{verb.id} — brandnana portal</title>
</svelte:head>

<div class="mb-5">
  <a href="/app/verbs" class="text-fg-muted text-xs no-underline hover:text-fg">← verbs</a>
</div>

<!-- Header -->
<div class="mb-8 pb-5 border-b border-border-warm">
  <h1 class="font-mono text-xl font-semibold text-fg mb-2.5">{verb.id}</h1>
  <div class="flex items-center gap-2.5 mb-2.5">
    <span class="font-mono text-xs font-bold uppercase tracking-wider" style="color: {methodColor(verb.httpMethod)}">{verb.httpMethod}</span>
    <code class="font-mono text-sm text-fg-muted">{verb.httpPath}</code>
  </div>
  <p class="text-fg text-sm m-0">{verb.summary}</p>
</div>

<!-- Description -->
{#if verb.description}
  <section class="bg-bg-cream border border-border-warm rounded-sm p-4 mb-6">
    <h2 class="section-title">Description</h2>
    <p class="text-fg text-xs leading-relaxed whitespace-pre-wrap">{verb.description}</p>
  </section>
{/if}

<!-- Inputs -->
{#if verb.inputs.length > 0}
  <section class="bg-bg-cream border border-border-warm rounded-sm p-4 mb-6">
    <h2 class="section-title">Inputs</h2>
    <div class="overflow-x-auto">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Required</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          {#each verb.inputs as input (input.name)}
            <tr>
              <td><code class="font-mono text-xs text-fg">{input.name}</code></td>
              <td><code class="font-mono text-xs text-burnt">{input.type}</code></td>
              <td>
                {#if input.required}
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded-sm text-xs font-semibold bg-banana/20 text-banana-deep border border-banana/40">yes</span>
                {:else}
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded-sm text-xs bg-bg-cream-soft text-fg-subtle border border-border-warm">no</span>
                {/if}
              </td>
              <td class="text-fg-muted text-xs max-w-xs">{input.description}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  </section>
{/if}

<!-- Output -->
<section class="bg-bg-cream border border-border-warm rounded-sm p-4 mb-6">
  <h2 class="section-title">Output</h2>
  <code class="font-mono text-xs text-burnt bg-white border border-border-warm px-2 py-1 rounded-sm inline-block">{verb.outputs}</code>
</section>

<!-- Snippets -->
<section class="bg-bg-cream border border-border-warm rounded-sm p-4 mb-6">
  <h2 class="section-title">Snippets</h2>
  <div class="flex gap-1 mb-3 border-b border-border-warm pb-0">
    {#each tabs as tab}
      <button
        class="bg-none border-none border-b-2 text-fg-muted cursor-pointer font-mono text-xs px-3 py-1.5 mb-[-1px] transition-colors hover:text-fg"
        class:tab-active={activeTab === tab.id}
        onclick={() => (activeTab = tab.id)}
      >
        {tab.label}
      </button>
    {/each}
  </div>
  <div class="mt-3">
    <CodeBlock code={snippetContent} lang={snippetLang} />
  </div>
</section>

<style>
  .tab-active {
    color: var(--color-fg) !important;
    border-bottom-color: var(--color-banana-deep) !important;
  }
</style>
