<script lang="ts" generics="T extends string | number">
  /**
   * Dropdown — canonical Svelte select. Replaces native `<select>`
   * everywhere so the popover styling, hover/focus states, and
   * keyboard nav match the rest of the app instead of inheriting the
   * OS combobox.
   *
   * Features:
   *   - Click trigger toggles a popover anchored beneath
   *   - ↑/↓ navigates highlighted item, ↵ selects, Esc closes
   *   - Click-outside dismisses
   *   - Items can carry an optional `description` (rendered as a
   *     muted line under the label) and an `icon` lucide component
   *   - Width auto-fits the trigger; popover clamped to viewport
   *
   * API mirrors `<select>` minimally: `value` is $bindable, `items`
   * is the option list, `placeholder` shows when value is unset.
   */
  import { CaretDown as ChevronDown, Check } from "phosphor-svelte";
  import type { DropdownItem } from "./Dropdown.types";

  let {
    value = $bindable(),
    items,
    placeholder = "Select…",
    disabled = false,
    /** Optional class on the trigger button so callers can style
     *  the affordance (e.g. inline in a form row). */
    triggerClass = "",
    onchange,
  }: {
    value: T | undefined;
    items: DropdownItem<T>[];
    placeholder?: string;
    disabled?: boolean;
    triggerClass?: string;
    onchange?: (v: T) => void;
  } = $props();

  let open = $state(false);
  let triggerEl: HTMLButtonElement | undefined = $state();
  let popoverEl: HTMLDivElement | undefined = $state();
  let pos = $state<{ top: number; left: number; width: number } | null>(null);
  let highlighted = $state(0);

  const selected = $derived(items.find((it) => it.value === value));
  const enabledIndices = $derived(
    items.map((it, i) => (it.disabled ? -1 : i)).filter((i) => i >= 0),
  );

  async function openMenu() {
    if (disabled || open) {
      open = false;
      return;
    }
    // Highlight current selection (or first enabled item).
    const sel = items.findIndex((it) => it.value === value);
    highlighted =
      sel >= 0 ? sel : enabledIndices.length > 0 ? enabledIndices[0] : 0;
    open = true;
    queueMicrotask(reposition);
  }

  function reposition() {
    if (!triggerEl) return;
    const r = triggerEl.getBoundingClientRect();
    const width = r.width;
    let top = r.bottom + 4;
    let left = r.left;
    // Clamp to viewport horizontally.
    if (left + width > window.innerWidth - 8) {
      left = Math.max(8, window.innerWidth - width - 8);
    }
    // Flip upward if there isn't enough room below.
    const estH = Math.min(items.length * 36 + 12, 320);
    if (top + estH > window.innerHeight - 8) {
      top = Math.max(8, r.top - estH - 4);
    }
    pos = { top, left, width };
  }

  $effect(() => {
    if (!open) return;
    function clickAway(e: MouseEvent) {
      const t = e.target as Node;
      if (popoverEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
    }
    function key(e: KeyboardEvent) {
      if (!open) return;
      if (e.key === "Escape") {
        e.preventDefault();
        open = false;
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        const cur = enabledIndices.indexOf(highlighted);
        const next = enabledIndices[Math.min(cur + 1, enabledIndices.length - 1)];
        if (next !== undefined) highlighted = next;
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        const cur = enabledIndices.indexOf(highlighted);
        const prev = enabledIndices[Math.max(cur - 1, 0)];
        if (prev !== undefined) highlighted = prev;
      } else if (e.key === "Enter") {
        e.preventDefault();
        const it = items[highlighted];
        if (it && !it.disabled) pick(it);
      } else if (e.key === "Home") {
        e.preventDefault();
        if (enabledIndices.length > 0) highlighted = enabledIndices[0];
      } else if (e.key === "End") {
        e.preventDefault();
        if (enabledIndices.length > 0)
          highlighted = enabledIndices[enabledIndices.length - 1];
      }
    }
    document.addEventListener("mousedown", clickAway);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    return () => {
      document.removeEventListener("mousedown", clickAway);
      document.removeEventListener("keydown", key);
      window.removeEventListener("resize", reposition);
      window.removeEventListener("scroll", reposition, true);
    };
  });

  function pick(it: DropdownItem<T>) {
    if (it.disabled) return;
    value = it.value;
    open = false;
    onchange?.(it.value);
  }

  function triggerKey(e: KeyboardEvent) {
    if (disabled) return;
    if (e.key === " " || e.key === "Enter" || e.key === "ArrowDown") {
      e.preventDefault();
      openMenu();
    }
  }
</script>

<button
  bind:this={triggerEl}
  type="button"
  class="trigger {triggerClass}"
  class:open
  class:placeholder={!selected}
  disabled={disabled}
  aria-haspopup="listbox"
  aria-expanded={open}
  onclick={openMenu}
  onkeydown={triggerKey}
>
  {#if selected?.icon}
    {@const Icon = selected.icon}
    <span class="trigger-icon"><Icon size={13} weight="fill" /></span>
  {/if}
  <span class="trigger-label">{selected?.label ?? placeholder}</span>
  <ChevronDown weight="bold" size={12} class="chev" />
</button>

{#if open && pos}
  <div
    bind:this={popoverEl}
    class="popover"
    role="listbox"
    style="top: {pos.top}px; left: {pos.left}px; min-width: {pos.width}px"
  >
    {#each items as it, i (it.value)}
      <button
        type="button"
        class="item"
        class:highlighted={i === highlighted}
        class:selected={it.value === value}
        class:disabled={it.disabled}
        role="option"
        aria-selected={it.value === value}
        aria-disabled={it.disabled}
        disabled={it.disabled}
        onmouseenter={() => !it.disabled && (highlighted = i)}
        onclick={() => pick(it)}
      >
        {#if it.icon}
          {@const Icon = it.icon}
          <span class="item-icon"><Icon size={13} weight="fill" /></span>
        {/if}
        <span class="item-body">
          <span class="item-label">{it.label}</span>
          {#if it.description}
            <span class="item-desc">{it.description}</span>
          {/if}
        </span>
        {#if it.value === value}
          <Check weight="bold" size={12} class="check" />
        {/if}
      </button>
    {/each}
  </div>
{/if}

<style>
  .trigger {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    height: 30px;
    padding: 0 0.55rem 0 0.6rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.84rem;
    cursor: pointer;
    transition: border-color 0.1s, background 0.1s;
    min-width: 0;
  }
  .trigger:hover:not(:disabled) { border-color: var(--color-border-strong); }
  .trigger:focus-visible {
    outline: 0;
    border-color: var(--color-border-strong);
    box-shadow: 0 0 0 3px var(--color-ring);
  }
  .trigger:disabled { opacity: 0.5; cursor: default; }
  .trigger.open { border-color: var(--color-border-strong); }
  .trigger.placeholder .trigger-label { color: var(--color-fg-subtle); }

  .trigger-icon {
    display: inline-flex;
    align-items: center;
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .trigger-label {
    flex: 1 1 auto;
    text-align: left;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .trigger :global(.chev) {
    color: var(--color-fg-muted);
    flex-shrink: 0;
    transition: transform 0.12s;
  }
  .trigger.open :global(.chev) { transform: rotate(180deg); }

  .popover {
    position: fixed;
    z-index: 1500;
    max-width: 360px;
    max-height: 320px;
    overflow-y: auto;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    box-shadow: var(--shadow-pop);
    padding: 4px;
    color: var(--color-fg);
    animation: pop-in 0.1s ease-out;
  }
  @keyframes pop-in {
    from { opacity: 0; transform: translateY(-3px); }
    to { opacity: 1; transform: translateY(0); }
  }

  .item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 0.45rem 0.6rem;
    border: 0;
    background: transparent;
    border-radius: 6px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.84rem;
    cursor: pointer;
    text-align: left;
  }
  .item.highlighted:not(.disabled) { background: var(--color-surface-soft); }
  .item.selected { font-weight: 500; }
  .item.disabled {
    color: var(--color-fg-subtle);
    cursor: default;
  }
  .item-icon {
    display: inline-flex;
    align-items: center;
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .item-body {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .item-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .item-desc {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .item :global(.check) {
    color: var(--color-fg);
    flex-shrink: 0;
  }
</style>
