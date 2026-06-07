<script lang="ts">
  /**
   * AgentIconPicker — anchored popover for picking an agent's :ICON:.
   *
   * Same pattern as workspace IconPickerMenu (click the icon tile,
   * popover opens with a menu of source options), extended with a
   * full Lucide search beside the emoji picker. Three stages:
   *
   *   menu   — choose Emoji | Icon library | Clear (→ initials)
   *   emoji  — emoji-picker-element search
   *   lucide — fuzzy filter across the curated Lucide map
   *
   * Bound value matches AgentIcon's input format:
   *   ""                  → initials
   *   "emoji:<glyph>"     → emoji
   *   "lucide:<IconName>" → lucide icon
   *
   * Trigger is the AgentIcon itself rendered at the requested size.
   * Picking dismisses the popover and fires `onchange`.
   */
  import { onMount, tick } from "svelte";
  import { Smile, Shapes, X, Search } from "@lucide/svelte";
  import AgentIcon from "./AgentIcon.svelte";
  import { LUCIDE_NAMES } from "./agent_lucide_map";
  import EmojiPicker from "$lib/workspace/EmojiPicker.svelte";

  let {
    value = $bindable(""),
    title = "",
    slug = "",
    size = 32,
    onchange,
  }: {
    value: string;
    title?: string;
    slug?: string;
    size?: number;
    onchange?: (v: string) => void;
  } = $props();

  type Stage = "menu" | "emoji" | "lucide";

  let open = $state(false);
  let stage = $state<Stage>("menu");
  let triggerEl = $state<HTMLButtonElement | null>(null);
  let popoverEl = $state<HTMLDivElement | null>(null);
  let pos = $state<{ top: number; left: number; w: number; h: number } | null>(
    null,
  );

  let lucideQuery = $state("");
  let lucideHighlight = $state(0);

  const lucideFiltered = $derived<string[]>(
    (() => {
      const q = lucideQuery.trim().toLowerCase();
      if (!q) return LUCIDE_NAMES;
      return LUCIDE_NAMES.filter((n) => n.toLowerCase().includes(q));
    })(),
  );

  async function openMenu() {
    if (open) {
      open = false;
      return;
    }
    stage = "menu";
    open = true;
    lucideQuery = "";
    await reposition();
  }

  async function reposition() {
    await tick();
    if (!triggerEl) return;
    const r = triggerEl.getBoundingClientRect();
    const w = stage === "emoji" ? 340 : stage === "lucide" ? 360 : 220;
    const h = stage === "emoji" ? 420 : stage === "lucide" ? 380 : 180;
    let left = r.right + 8;
    let top = r.top;
    // Flip left if no room.
    if (left + w > window.innerWidth - 8) {
      left = Math.max(8, r.left - w - 8);
    }
    // Pull up if no room below.
    if (top + h > window.innerHeight - 8) {
      top = Math.max(8, window.innerHeight - h - 8);
    }
    pos = { top, left, w, h };
  }

  function setValue(v: string) {
    value = v;
    onchange?.(v);
    open = false;
    stage = "menu";
  }

  function pickEmoji(glyph: string) {
    setValue(`emoji:${glyph}`);
  }

  function pickLucide(name: string) {
    setValue(`lucide:${name}`);
  }

  function clearIcon() {
    setValue("");
  }

  $effect(() => {
    if (!open) return;
    void reposition();
    function away(e: MouseEvent) {
      const t = e.target as Node;
      if (popoverEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
      stage = "menu";
    }
    function key(e: KeyboardEvent) {
      if (e.key === "Escape") {
        open = false;
        stage = "menu";
      }
    }
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", key);
      window.removeEventListener("resize", reposition);
      window.removeEventListener("scroll", reposition, true);
    };
  });

  // Watch stage transitions to reposition for the right popover size.
  $effect(() => {
    void stage;
    if (open) void reposition();
  });

  function onLucideKey(e: KeyboardEvent) {
    if (lucideFiltered.length === 0) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      lucideHighlight = Math.min(
        lucideHighlight + 1,
        lucideFiltered.length - 1,
      );
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      lucideHighlight = Math.max(lucideHighlight - 1, 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const name = lucideFiltered[lucideHighlight];
      if (name) pickLucide(name);
    }
  }
</script>

<button
  type="button"
  bind:this={triggerEl}
  class="trigger"
  style:width="{size}px"
  style:height="{size}px"
  aria-label="Pick agent icon"
  aria-expanded={open}
  onclick={openMenu}
>
  <AgentIcon icon={value} title={title} slug={slug} size={size} />
</button>

{#if open && pos}
  <div
    bind:this={popoverEl}
    class="popover"
    style:top="{pos.top}px"
    style:left="{pos.left}px"
    style:width="{pos.w}px"
    role="dialog"
    aria-label="Icon picker"
  >
    {#if stage === "menu"}
      <div class="menu">
        <button class="opt" type="button" onclick={() => (stage = "emoji")}>
          <Smile size={14} strokeWidth={1.8} aria-hidden="true" />
          <span>Pick emoji</span>
        </button>
        <button class="opt" type="button" onclick={() => (stage = "lucide")}>
          <Shapes size={14} strokeWidth={1.8} aria-hidden="true" />
          <span>Icon library</span>
        </button>
        <div class="sep"></div>
        <button class="opt muted" type="button" onclick={clearIcon}>
          <X size={14} strokeWidth={1.8} aria-hidden="true" />
          <span>Clear (use initials)</span>
        </button>
      </div>
    {:else if stage === "emoji"}
      <header class="head">
        <button class="back" type="button" onclick={() => (stage = "menu")}>← Back</button>
        <span class="title">Emoji</span>
      </header>
      <EmojiPicker onpick={pickEmoji} />
    {:else if stage === "lucide"}
      <header class="head">
        <button class="back" type="button" onclick={() => (stage = "menu")}>← Back</button>
        <span class="title">Icon library</span>
        <span class="count">{lucideFiltered.length}</span>
      </header>
      <div class="search">
        <Search size={12} strokeWidth={1.8} aria-hidden="true" />
        <input
          type="text"
          placeholder="Search {LUCIDE_NAMES.length} icons…"
          bind:value={lucideQuery}
          oninput={() => (lucideHighlight = 0)}
          onkeydown={onLucideKey}
        />
      </div>
      <div class="grid">
        {#if lucideFiltered.length === 0}
          <div class="empty">No icons match "{lucideQuery}"</div>
        {:else}
          {#each lucideFiltered as name, i (name)}
            <button
              type="button"
              class="grid-item"
              class:active={i === lucideHighlight}
              title={name}
              onclick={() => pickLucide(name)}
              onmouseenter={() => (lucideHighlight = i)}
            >
              <AgentIcon icon="lucide:{name}" size={20} />
            </button>
          {/each}
        {/if}
      </div>
    {/if}
  </div>
{/if}

<style>
  .trigger {
    background: transparent;
    border: 0;
    padding: 0;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 6px;
  }
  .trigger:hover {
    background: var(--color-surface-soft);
  }
  .popover {
    position: fixed;
    z-index: 1300;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    box-shadow: var(--shadow-pop, 0 10px 30px rgba(0, 0, 0, 0.35));
    overflow: hidden;
    display: flex;
    flex-direction: column;
    max-height: 80vh;
  }
  .menu {
    display: flex;
    flex-direction: column;
    padding: 0.3rem;
  }
  .opt {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.55rem 0.7rem;
    background: transparent;
    border: 0;
    border-radius: 6px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    cursor: pointer;
    text-align: left;
  }
  .opt:hover {
    background: var(--color-surface-soft);
  }
  .opt.muted {
    color: var(--color-fg-muted);
  }
  .sep {
    height: 1px;
    background: var(--color-border);
    margin: 0.25rem 0;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.45rem 0.6rem;
    border-bottom: 1px solid var(--color-border);
    flex-shrink: 0;
    background: var(--color-page);
  }
  .back {
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.78rem;
    cursor: pointer;
    padding: 0.1rem 0.4rem;
    border-radius: 4px;
  }
  .back:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .title {
    font-size: 0.78rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-fg-subtle);
  }
  .count {
    margin-left: auto;
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
    background: var(--color-surface-soft);
    padding: 0.05em 0.5em;
    border-radius: 999px;
  }
  .search {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.5rem 0.6rem;
    border-bottom: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .search input {
    flex: 1;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    outline: none;
  }
  .grid {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 0.4rem;
    display: grid;
    grid-template-columns: repeat(8, 1fr);
    gap: 0.15rem;
  }
  .grid-item {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0.45rem;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 5px;
    cursor: pointer;
    color: var(--color-fg);
  }
  .grid-item:hover,
  .grid-item.active {
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .empty {
    grid-column: 1 / -1;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
    text-align: center;
    padding: 1.5rem 0.5rem;
  }
</style>
