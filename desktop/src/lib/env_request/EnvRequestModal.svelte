<script lang="ts">
  /**
   * Env-request modal — the desktop surface for `wb env request`.
   *
   * Deliberately minimal: a logo of the source (resolved from the var name via
   * the icon library), one plain sentence, the field, and two buttons. The
   * value never reaches the agent — it goes straight to the engine over
   * `engine:env_prompt` as `env:fulfill`. Stored locked by default (the secure
   * choice); we don't make the user reason about that.
   */
  import { envRequests } from "./store.svelte";
  import Icon from "$lib/ui/Icon.svelte";
  import { Key } from "phosphor-svelte";

  let value = $state("");
  let acting = $state(false);

  const req = $derived(envRequests.current);

  // Resolve the var name → a friendly service label + a brand icon. AI/dev
  // providers map to LobeHub marks; unknowns get a humanized label + a key glyph.
  const KNOWN: Record<string, { slug: string; label: string }> = {
    openai: { slug: "openai", label: "OpenAI" },
    openrouter: { slug: "openrouter", label: "OpenRouter" },
    anthropic: { slug: "anthropic", label: "Anthropic" },
    claude: { slug: "claude", label: "Claude" },
    gemini: { slug: "gemini-color", label: "Gemini" },
    google: { slug: "gemini-color", label: "Google" },
    groq: { slug: "groq", label: "Groq" },
    mistral: { slug: "mistral", label: "Mistral" },
    cohere: { slug: "cohere", label: "Cohere" },
    perplexity: { slug: "perplexity", label: "Perplexity" },
    replicate: { slug: "replicate", label: "Replicate" },
    huggingface: { slug: "huggingface", label: "Hugging Face" },
    hf: { slug: "huggingface", label: "Hugging Face" },
    elevenlabs: { slug: "elevenlabs", label: "ElevenLabs" },
    deepgram: { slug: "deepgram", label: "Deepgram" },
    xai: { slug: "grok", label: "xAI" },
    grok: { slug: "grok", label: "Grok" },
    deepseek: { slug: "deepseek", label: "DeepSeek" },
    minimax: { slug: "minimax", label: "MiniMax" },
    stripe: { slug: "stripe", label: "Stripe" },
    github: { slug: "github", label: "GitHub" },
    cloudflare: { slug: "cloudflare", label: "Cloudflare" },
    fly: { slug: "flyio", label: "Fly.io" },
    recraft: { slug: "recraft", label: "Recraft" },
    dataforseo: { slug: "", label: "DataForSEO" },
  };

  function humanize(s: string): string {
    return s
      .split(/[_\- ]+/)
      .filter(Boolean)
      .map((w) => w[0].toUpperCase() + w.slice(1))
      .join(" ");
  }

  const source = $derived.by(() => {
    const name = req?.name ?? "";
    const base = name
      .toLowerCase()
      .replace(/_?(api[_-]?)?(key|token|secret|password)s?$/, "")
      .replace(/[_-]+$/, "");
    const hit = KNOWN[base];
    if (hit) return { label: hit.label, icon: hit.slug ? `lobe:${hit.slug}` : null };
    return { label: base ? humanize(base) : name, icon: null };
  });

  async function onProvide() {
    if (!req || acting || value.length === 0) return;
    acting = true;
    try {
      await envRequests.fulfill(value, true); // stored locked — the secure default
      value = "";
    } finally {
      acting = false;
    }
  }

  async function onCancel() {
    if (!req || acting) return;
    acting = true;
    try {
      await envRequests.cancel();
      value = "";
    } finally {
      acting = false;
    }
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Enter") void onProvide();
    if (e.key === "Escape") void onCancel();
  }
</script>

{#if req}
  <div class="overlay" data-testid="env-request-overlay">
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="env-title">
      <div class="logo" aria-hidden="true">
        {#if source.icon}
          <Icon value={source.icon} name={source.label} size={28} />
        {:else}
          <Key weight="fill" size={24} />
        {/if}
      </div>

      <h2 id="env-title">Enter your {source.label} key</h2>
      <p class="sub">{req.reason ?? `Waldo needs it to keep going. It's stored on this device only.`}</p>

      <input
        id="env-value"
        type="password"
        autocomplete="off"
        spellcheck="false"
        bind:value
        disabled={acting}
        onkeydown={onKey}
        data-testid="env-request-value"
        placeholder={req.hint ?? `Paste your ${source.label} key`}
      />

      <div class="actions">
        <button class="btn cancel" onclick={onCancel} disabled={acting} data-testid="env-request-cancel">
          Not now
        </button>
        <button
          class="btn provide"
          onclick={onProvide}
          disabled={acting || value.length === 0}
          data-testid="env-request-provide"
        >
          Save key
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    backdrop-filter: blur(2px);
    z-index: 9999;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
  }
  .modal {
    background: var(--color-surface);
    color: var(--color-fg);
    border: 1px solid var(--color-border);
    border-radius: 16px;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.28);
    padding: 1.6rem 1.5rem 1.25rem;
    width: 100%;
    max-width: 360px;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.5rem;
  }
  .logo {
    width: 52px;
    height: 52px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 13px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    margin-bottom: 0.15rem;
  }
  h2 {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .sub {
    margin: 0 0 0.5rem;
    font-size: 0.85rem;
    line-height: 1.45;
    color: var(--color-fg-muted);
    max-width: 30ch;
  }
  input[type="password"] {
    width: 100%;
    padding: 0.55rem 0.7rem;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font-size: 0.9rem;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    text-align: center;
  }
  input[type="password"]:focus {
    outline: none;
    border-color: var(--color-brand, var(--color-fg-subtle));
  }
  .actions {
    display: flex;
    gap: 0.5rem;
    width: 100%;
    margin-top: 0.6rem;
  }
  .btn {
    flex: 1;
    height: 38px;
    border-radius: 10px;
    font-size: 0.88rem;
    font-weight: 550;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    transition: opacity 0.12s, filter 0.12s;
  }
  .btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .btn.provide {
    background: var(--color-brand, var(--color-fg));
    color: #fff;
    border-color: transparent;
  }
  .btn.provide:not(:disabled):hover {
    filter: brightness(1.06);
  }
  .btn.cancel:not(:disabled):hover {
    background: var(--color-surface);
  }
</style>
