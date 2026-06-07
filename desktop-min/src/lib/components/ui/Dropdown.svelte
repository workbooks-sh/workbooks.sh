<script lang="ts" generics="T extends string | number">
  /**
   * Dropdown — the canonical select, replacing native <select> so the
   * popover, hover/focus, and keyboard nav match the app chrome.
   *
   *   - click / Space / Enter / ↓ opens the popover anchored beneath
   *   - ↑/↓ move the highlight, ↵ picks, Esc closes, click-outside dismisses
   *   - popover is fixed-positioned and clamped to the viewport (flips up
   *     when there isn't room below)
   *
   * `value` is $bindable; `items` is the option list; `placeholder`
   * shows when value is unset.
   */
  import { ChevronDown, Check } from "@lucide/svelte";
  import type { DropdownItem } from "./Dropdown.types";

  let {
    value = $bindable(),
    items,
    placeholder = "Select…",
    disabled = false,
    onchange,
  }: {
    value: T | undefined;
    items: DropdownItem<T>[];
    placeholder?: string;
    disabled?: boolean;
    onchange?: (v: T) => void;
  } = $props();

  let open = $state(false);
  let triggerEl: HTMLButtonElement | undefined = $state();
  let popoverEl: HTMLDivElement | undefined = $state();
  let pos = $state<{ top: number; left: number; width: number } | null>(null);
  let hi = $state(0);

  const selected = $derived(items.find((it) => it.value === value));
  const enabled = $derived(
    items.map((it, i) => (it.disabled ? -1 : i)).filter((i) => i >= 0),
  );

  function toggle() {
    if (disabled) return;
    if (open) { open = false; return; }
    const sel = items.findIndex((it) => it.value === value);
    hi = sel >= 0 ? sel : (enabled[0] ?? 0);
    open = true;
    queueMicrotask(place);
  }

  function place() {
    if (!triggerEl) return;
    const r = triggerEl.getBoundingClientRect();
    let top = r.bottom + 4;
    let left = Math.min(r.left, window.innerWidth - r.width - 8);
    const estH = Math.min(items.length * 36 + 8, 320);
    if (top + estH > window.innerHeight - 8) top = Math.max(8, r.top - estH - 4);
    pos = { top, left: Math.max(8, left), width: r.width };
  }

  function pick(it: DropdownItem<T>) {
    if (it.disabled) return;
    value = it.value;
    open = false;
    onchange?.(it.value);
  }

  function move(d: number) {
    const cur = enabled.indexOf(hi);
    const next = enabled[Math.min(Math.max(cur + d, 0), enabled.length - 1)];
    if (next !== undefined) hi = next;
  }

  $effect(() => {
    if (!open) return;
    function away(e: MouseEvent) {
      const t = e.target as Node;
      if (!popoverEl?.contains(t) && !triggerEl?.contains(t)) open = false;
    }
    function key(e: KeyboardEvent) {
      if (e.key === "Escape") { e.preventDefault(); open = false; }
      else if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
      else if (e.key === "Enter") { e.preventDefault(); const it = items[hi]; if (it) pick(it); }
    }
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", key);
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  });
</script>

<button
  bind:this={triggerEl}
  type="button"
  class="trigger"
  class:open
  {disabled}
  aria-haspopup="listbox"
  aria-expanded={open}
  onclick={toggle}
  onkeydown={(e) => {
    if (e.key === " " || e.key === "ArrowDown") { e.preventDefault(); toggle(); }
  }}
>
  {#if selected?.icon}
    {@const Icon = selected.icon}
    <span class="t-ico"><Icon size={13} strokeWidth={1.8} /></span>
  {/if}
  <span class="t-lbl" class:ph={!selected}>{selected?.label ?? placeholder}</span>
  <ChevronDown size={12} strokeWidth={2} class="chev" />
</button>

{#if open && pos}
  <div
    bind:this={popoverEl}
    class="popover"
    role="listbox"
    style="top:{pos.top}px; left:{pos.left}px; min-width:{pos.width}px"
  >
    {#each items as it, i (it.value)}
      <button
        type="button"
        class="item"
        class:hi={i === hi}
        class:disabled={it.disabled}
        role="option"
        aria-selected={it.value === value}
        disabled={it.disabled}
        onmouseenter={() => !it.disabled && (hi = i)}
        onclick={() => pick(it)}
      >
        {#if it.icon}
          {@const Icon = it.icon}
          <span class="i-ico"><Icon size={13} strokeWidth={1.8} /></span>
        {/if}
        <span class="i-body">
          <span class="i-lbl">{it.label}</span>
          {#if it.description}<span class="i-desc">{it.description}</span>{/if}
        </span>
        {#if it.value === value}<Check size={12} strokeWidth={2.4} class="check" />{/if}
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
  }
  .trigger:hover:not(:disabled), .trigger.open { border-color: var(--color-border-strong); }
  .trigger:focus-visible {
    outline: 0;
    border-color: var(--color-border-strong);
    box-shadow: 0 0 0 3px var(--color-ring);
  }
  .trigger:disabled { opacity: 0.5; cursor: default; }
  .t-ico { display: inline-flex; color: var(--color-fg-muted); flex-shrink: 0; }
  .t-lbl { flex: 1 1 auto; text-align: left; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .t-lbl.ph { color: var(--color-fg-subtle); }
  .trigger :global(.chev) { color: var(--color-fg-muted); flex-shrink: 0; transition: transform 0.12s; }
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
  .item.hi:not(.disabled) { background: var(--color-surface-soft); }
  .item.disabled { color: var(--color-fg-subtle); cursor: default; }
  .i-ico { display: inline-flex; color: var(--color-fg-muted); flex-shrink: 0; }
  .i-body { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .i-lbl { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .i-desc { font-size: 0.72rem; color: var(--color-fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .item :global(.check) { color: var(--color-fg); flex-shrink: 0; }
</style>
