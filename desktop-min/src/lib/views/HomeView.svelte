<script lang="ts">
  /**
   * HomeView (Create) — minimalist landing for starting work. A composer
   * plus explicit create buttons, matching the old HomePanel's shape.
   * Wiring to agents/voice/skills is deferred; the surface is here.
   */
  import { Plus, Sparkles } from "@lucide/svelte";

  let prompt = $state("");
  const creators = ["Board", "Package", "Workbook", "Skill"];
</script>

<section class="home">
  <button class="ask">
    <Sparkles size={14} strokeWidth={1.8} /> Ask the workspace
  </button>

  <div class="composer">
    <textarea
      bind:value={prompt}
      placeholder="Describe what you want to build…"
      rows="3"
    ></textarea>
    <div class="row">
      {#each creators as c (c)}
        <button class="chip"><Plus size={12} strokeWidth={2} /> {c}</button>
      {/each}
    </div>
  </div>
</section>

<style>
  .home {
    max-width: 640px;
    margin: 0 auto;
    padding: 3rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .ask {
    align-self: flex-start;
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    height: 28px;
    padding: 0 0.7rem;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    cursor: pointer;
  }
  .ask:hover {
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .composer {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    padding: 0.75rem;
    box-shadow: var(--shadow-pop);
  }
  textarea {
    width: 100%;
    border: 0;
    outline: 0;
    resize: none;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.9rem;
    line-height: 1.45;
  }
  .row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin-top: 0.5rem;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    height: 26px;
    padding: 0 0.6rem;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    font-size: 0.76rem;
    cursor: pointer;
  }
  .chip:hover {
    color: var(--color-fg);
  }
</style>
