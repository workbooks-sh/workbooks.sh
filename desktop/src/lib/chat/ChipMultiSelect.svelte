<script lang="ts">
  /**
   * ChipMultiSelect — multi-select via toggleable chips. Used in the
   * agent editor for tools + capabilities. Replaces space-separated
   * text inputs — no more "what are the right tool names?" guesswork.
   *
   * Bound `value` is a whitespace-joined string (the on-disk format
   * for :TOOLS: and :CAPABILITIES: drawer properties). The component
   * parses it into a Set internally and emits a fresh joined string
   * on every toggle.
   *
   * `available` is the curated list of options surfaced first.
   * Items in `value` that aren't in `available` show as "custom"
   * chips (typed by hand or imported from an existing file) — they
   * stay selected until removed but don't appear in the picker.
   */
  import { X, Plus, Check } from "phosphor-svelte";

  let {
    value = $bindable(""),
    available,
    placeholder = "Add…",
    allowCustom = true,
    onchange,
  }: {
    value: string;
    available: string[];
    placeholder?: string;
    allowCustom?: boolean;
    onchange?: (v: string) => void;
  } = $props();

  // Parse the joined string into an ordered Set. Preserve user order
  // so the chip row matches what's on disk.
  const selected = $derived<string[]>(
    value
      .split(/\s+/)
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const selectedSet = $derived(new Set(selected));

  // Available picks not already selected.
  const remaining = $derived<string[]>(
    available.filter((a) => !selectedSet.has(a)),
  );

  let customInput = $state("");
  let pickerOpen = $state(false);
  let addBtnEl = $state<HTMLButtonElement | null>(null);
  let pickerEl = $state<HTMLDivElement | null>(null);
  // Fixed-position coords so the picker escapes any ancestor
  // `overflow: hidden` (e.g. the AgentEditor modal).
  let pos = $state<{ top: number; left: number } | null>(null);

  const PICKER_WIDTH = 220;
  const PICKER_HEIGHT_EST = 320;

  function reposition() {
    if (!addBtnEl) return;
    const r = addBtnEl.getBoundingClientRect();
    let top = r.bottom + 4;
    let left = r.left;
    if (left + PICKER_WIDTH > window.innerWidth - 8) {
      left = Math.max(8, window.innerWidth - PICKER_WIDTH - 8);
    }
    if (top + PICKER_HEIGHT_EST > window.innerHeight - 8) {
      top = Math.max(8, r.top - PICKER_HEIGHT_EST - 4);
    }
    pos = { top, left };
  }

  function togglePicker() {
    pickerOpen = !pickerOpen;
    if (pickerOpen) queueMicrotask(reposition);
  }

  $effect(() => {
    if (!pickerOpen) return;
    reposition();
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    return () => {
      window.removeEventListener("resize", reposition);
      window.removeEventListener("scroll", reposition, true);
    };
  });

  function emit(next: string[]) {
    value = next.join(" ");
    onchange?.(value);
  }

  function toggle(item: string) {
    if (selectedSet.has(item)) {
      emit(selected.filter((s) => s !== item));
    } else {
      emit([...selected, item]);
    }
  }

  function remove(item: string) {
    emit(selected.filter((s) => s !== item));
  }

  function addCustom() {
    const next = customInput.trim();
    if (!next) return;
    if (selectedSet.has(next)) {
      customInput = "";
      return;
    }
    emit([...selected, next]);
    customInput = "";
  }

  function onCustomKey(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      addCustom();
    }
  }
</script>

<div class="chips">
  {#each selected as item (item)}
    {@const isStandard = available.includes(item)}
    <span class="chip" class:custom={!isStandard}>
      {item}
      <button
        type="button"
        class="chip-x"
        aria-label="Remove {item}"
        onclick={() => remove(item)}
      >
        <X weight="bold" size={10} aria-hidden="true" />
      </button>
    </span>
  {/each}
  <div class="add-wrap">
    <button
      type="button"
      bind:this={addBtnEl}
      class="add"
      onclick={togglePicker}
      aria-expanded={pickerOpen}
    >
      <Plus weight="bold" size={11} aria-hidden="true" />
      <span>{placeholder}</span>
    </button>
    {#if pickerOpen && pos}
      <div
        bind:this={pickerEl}
        class="picker"
        style:top="{pos.top}px"
        style:left="{pos.left}px"
        style:width="{PICKER_WIDTH}px"
      >
        {#if remaining.length === 0 && !allowCustom}
          <div class="empty">All options added.</div>
        {/if}
        {#each remaining as item (item)}
          <button
            type="button"
            class="picker-row"
            onclick={() => {
              toggle(item);
            }}
          >
            <Check weight="bold" size={11} class="invisible" aria-hidden="true" />
            <span>{item}</span>
          </button>
        {/each}
        {#if allowCustom}
          <div class="custom-input">
            <input
              type="text"
              placeholder="Custom…"
              bind:value={customInput}
              onkeydown={onCustomKey}
            />
            <button
              type="button"
              class="add-custom"
              disabled={!customInput.trim()}
              onclick={addCustom}
            >
              add
            </button>
          </div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<svelte:window
  onmousedown={(e) => {
    if (!pickerOpen) return;
    const t = e.target as Node;
    if (addBtnEl?.contains(t)) return;
    if (pickerEl?.contains(t)) return;
    pickerOpen = false;
  }}
/>

<style>
  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 0.3rem;
    align-items: center;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    padding: 0.15em 0.3em 0.15em 0.55em;
    border-radius: 4px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.72rem;
  }
  .chip.custom {
    border-style: dashed;
    color: var(--color-fg-muted);
  }
  .chip-x {
    background: transparent;
    border: 0;
    padding: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    border-radius: 2px;
  }
  .chip-x:hover {
    color: var(--color-fg);
    background: var(--color-border);
  }
  .add-wrap {
    position: relative;
  }
  .add {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    padding: 0.15em 0.55em;
    border-radius: 4px;
    background: transparent;
    border: 1px dashed var(--color-border);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.72rem;
    cursor: pointer;
  }
  .add:hover {
    color: var(--color-fg);
    border-color: var(--color-fg-subtle);
  }
  .picker {
    /* Fixed positioning so the picker escapes ancestor
     * `overflow: hidden` (e.g. the AgentEditor modal). Coords come
     * from getBoundingClientRect via reposition(). */
    position: fixed;
    z-index: 1300;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    box-shadow: var(--shadow-pop, 0 8px 24px rgba(0, 0, 0, 0.3));
    max-height: 320px;
    overflow-y: auto;
    padding: 0.25rem 0;
  }
  .picker-row {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    width: 100%;
    padding: 0.32rem 0.6rem;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.78rem;
    text-align: left;
    cursor: pointer;
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .picker-row:hover {
    background: var(--color-surface-soft);
  }
  :global(.picker-row .invisible) {
    opacity: 0;
  }
  .empty {
    padding: 0.5rem 0.7rem;
    font-size: 0.75rem;
    color: var(--color-fg-muted);
  }
  .custom-input {
    display: flex;
    gap: 0.25rem;
    padding: 0.35rem 0.45rem;
    border-top: 1px solid var(--color-border);
    margin-top: 0.25rem;
  }
  .custom-input input {
    flex: 1;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 4px;
    padding: 0.2rem 0.4rem;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.75rem;
    outline: none;
  }
  .add-custom {
    background: var(--color-fg);
    color: var(--color-page);
    border: 0;
    border-radius: 4px;
    padding: 0.2rem 0.55rem;
    font-size: 0.7rem;
    font-weight: 600;
    cursor: pointer;
  }
  .add-custom:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
</style>
