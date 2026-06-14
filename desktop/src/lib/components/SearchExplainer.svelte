<script lang="ts">
  /**
   * SearchExplainer — a small card that sits to the LEFT of the search drawer
   * and explains what the active search type does (shown during onboarding so
   * you understand each kind without over-specific names). Reads search.mode.
   */
  import { MagnifyingGlass, Globe, Sparkle } from "phosphor-svelte";
  import { search, WEB_PROVIDERS, type WebProvider } from "$lib/search/registry.svelte";
  import { SEARCH_MODES } from "$lib/search/modes";

  const info = $derived(SEARCH_MODES[search.mode]);
  const Icon = $derived(search.mode === "ai" ? Sparkle : search.mode === "web" ? Globe : MagnifyingGlass);

  // Friendly labels for the web-search backend picker (wb-e4jl / wb-ndlz).
  const PROVIDER_LABELS: Record<WebProvider, string> = {
    openrouter: "OpenRouter — reliable",
    keyless: "Keyless — no setup",
    exa: "Exa (needs key)",
    brave_api: "Brave API (needs key)",
    perplexity: "Perplexity (needs key)",
  };
</script>

<aside class="explainer" aria-label="About this search">
  {#key search.mode}
    <div class="card">
      <div class="ic"><Icon size={18} weight="fill" /></div>
      <span class="tag">{info.tagline}</span>
      <h3>{info.label}</h3>
      <p>{info.blurb}</p>
      {#if search.mode === "web"}
        <label class="prov">
          <span>Web search via</span>
          <select
            value={search.webProvider}
            onchange={(e) => search.setWebProvider(e.currentTarget.value as WebProvider)}
          >
            {#each WEB_PROVIDERS as p}
              <option value={p}>{PROVIDER_LABELS[p]}</option>
            {/each}
          </select>
        </label>
      {/if}
    </div>
  {/key}
</aside>

<style>
  .explainer {
    flex-shrink: 0;
    width: 230px;
    display: flex;
    align-items: center;
    margin: 0 0 8px 0;
    pointer-events: none;
  }
  .card {
    pointer-events: auto;
    margin: 0 6px;
    padding: 16px 16px 18px;
    border: 1px solid var(--color-border);
    border-radius: 14px;
    background: color-mix(in srgb, var(--color-surface) 92%, transparent);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    box-shadow:
      0 1px 2px rgba(15, 15, 15, 0.05),
      0 8px 28px rgba(15, 15, 15, 0.1);
    animation: ex-in 0.22s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .ic {
    display: grid;
    place-items: center;
    width: 34px;
    height: 34px;
    border-radius: 10px;
    background: var(--color-brand-soft);
    color: var(--color-brand);
    margin-bottom: 10px;
  }
  .tag {
    display: block;
    font-family: var(--font-mono);
    font-size: 0.64rem;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
  }
  h3 {
    margin: 2px 0 8px;
    font-size: 1.05rem;
    font-weight: 650;
    color: var(--color-fg);
  }
  p {
    margin: 0;
    font-size: 0.82rem;
    line-height: 1.5;
    color: var(--color-fg-muted);
  }
  .prov {
    display: block;
    margin-top: 12px;
  }
  .prov span {
    display: block;
    font-family: var(--font-mono);
    font-size: 0.6rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
    margin-bottom: 4px;
  }
  .prov select {
    width: 100%;
    padding: 6px 8px;
    font-size: 0.8rem;
    color: var(--color-fg);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    cursor: pointer;
  }
  @keyframes ex-in {
    from { opacity: 0; transform: translateY(6px); }
    to { opacity: 1; transform: translateY(0); }
  }
</style>
