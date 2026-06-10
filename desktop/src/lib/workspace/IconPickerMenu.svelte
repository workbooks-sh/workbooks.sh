<script lang="ts">
  /**
   * IconPickerMenu — click-the-tile UX for setting a workspace icon.
   *
   * The icon preview itself is the trigger. Clicking opens a popover
   * (3-option menu):
   *
   *   • Pick emoji        → swaps the panel to the emoji picker
   *   • Upload an image   → opens the OS file dialog
   *   • Use initials      → clears the icon
   *
   * Matches Studio's IconPickerMenu pattern (archive/studio/frontend/
   * src/lib/components/IconPickerMenu.svelte) so the two products
   * behave the same way.
   *
   * Single-field icon model (per docs/canonical-model.md decision):
   *   value === ""                      → initials
   *   value.startsWith("data:image/")  → image (data URL)
   *   otherwise                         → emoji
   *
   * Image upload is resized to 96×96 max via canvas (keeps the
   * workspaces.json compact). No crop modal in v1 — center-crop on
   * resize. SVGs pass through unmodified.
   */
  import { onMount, tick } from "svelte";
  import { ImageSquare as ImagePlus, Smiley as Smile, TextT as Type } from "phosphor-svelte";
  import EmojiPicker from "./EmojiPicker.svelte";

  let {
    value = $bindable(""),
    name,
    size = 64,
  }: {
    value: string;
    name: string;
    /** Trigger tile size (px). */
    size?: number;
  } = $props();

  type Stage = "menu" | "emoji";

  let open = $state(false);
  let stage = $state<Stage>("menu");
  let triggerEl = $state<HTMLButtonElement | null>(null);
  let popoverEl = $state<HTMLDivElement | null>(null);
  let popoverPos = $state<{ top: number; left: number } | null>(null);
  let fileInput = $state<HTMLInputElement | null>(null);
  let busy = $state(false);
  let error = $state<string | null>(null);

  function kindOf(v: string): "image" | "emoji" | "initials" {
    if (!v) return "initials";
    if (v.startsWith("data:image/")) return "image";
    return "emoji";
  }
  const kind = $derived(kindOf(value));

  function initials(n: string): string {
    const parts = n.trim().split(/[\s\-_]+/).filter(Boolean);
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return (n || "?").slice(0, 2).toUpperCase();
  }

  async function openMenu() {
    if (busy) return;
    if (open) { open = false; return; }
    stage = "menu";
    open = true;
    error = null;
    await positionPopover();
  }

  async function positionPopover() {
    await tick();
    if (!triggerEl) return;
    const r = triggerEl.getBoundingClientRect();
    const popW = stage === "emoji" ? 340 : 240;
    const popH = stage === "emoji" ? 420 : 180;
    let left = r.right + 8;
    let top = r.top;
    if (left + popW > window.innerWidth - 8) left = Math.max(8, r.left - popW - 8);
    if (top + popH > window.innerHeight - 8) top = Math.max(8, window.innerHeight - popH - 8);
    popoverPos = { top, left };
  }

  $effect(() => {
    if (!open) return;
    function away(e: MouseEvent) {
      const t = e.target as Node;
      if (popoverEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
    }
    function key(e: KeyboardEvent) { if (e.key === "Escape") open = false; }
    function reposition() { void positionPopover(); }
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

  $effect(() => {
    if (!open) return;
    void stage;
    void positionPopover();
  });

  function pickEmoji(unicode: string) {
    value = unicode;
    open = false;
  }

  function pickInitials() {
    value = "";
    open = false;
  }

  function pickImageClick() {
    fileInput?.click();
  }

  async function onImageInput(e: Event) {
    const input = e.target as HTMLInputElement;
    const f = input.files?.[0];
    input.value = "";
    if (!f) return;
    if (f.size > 2 * 1024 * 1024) {
      error = "Image must be under 2 MB.";
      return;
    }
    if (!/^image\/(png|jpeg|webp|svg\+xml)$/.test(f.type)) {
      error = "PNG, JPEG, WebP, or SVG only.";
      return;
    }
    busy = true;
    error = null;
    try {
      if (f.type === "image/svg+xml") {
        value = await readAsDataUrl(f);
      } else {
        value = await resizeToDataUrl(f, 96);
      }
      open = false;
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      busy = false;
    }
  }

  function readAsDataUrl(f: File): Promise<string> {
    return new Promise((resolve, reject) => {
      const fr = new FileReader();
      fr.onload = () => resolve(String(fr.result));
      fr.onerror = () => reject(fr.error ?? new Error("read failed"));
      fr.readAsDataURL(f);
    });
  }

  async function resizeToDataUrl(f: File, max: number): Promise<string> {
    const dataUrl = await readAsDataUrl(f);
    const img = new Image();
    await new Promise<void>((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error("image decode failed"));
      img.src = dataUrl;
    });
    const scale = Math.min(1, max / Math.max(img.width, img.height));
    const w = Math.round(img.width * scale);
    const h = Math.round(img.height * scale);
    const c = document.createElement("canvas");
    c.width = w;
    c.height = h;
    const ctx = c.getContext("2d");
    if (!ctx) throw new Error("canvas context unavailable");
    ctx.drawImage(img, 0, 0, w, h);
    // Prefer WebP when the browser supports it (smaller); fall back to PNG.
    const out = c.toDataURL("image/webp", 0.9);
    if (out.startsWith("data:image/webp")) return out;
    return c.toDataURL("image/png");
  }
</script>

<button
  bind:this={triggerEl}
  type="button"
  class="trigger"
  class:open
  aria-haspopup="menu"
  aria-expanded={open}
  aria-label="Change icon"
  onclick={openMenu}
  disabled={busy}
  style="width: {size}px; height: {size}px;"
>
  {#if kind === "image"}
    <img src={value} alt="" class="img" />
  {:else if kind === "emoji"}
    <span class="emoji" aria-hidden="true">{value}</span>
  {:else}
    <span class="initials" aria-hidden="true">{initials(name)}</span>
  {/if}
</button>

<input
  type="file"
  accept="image/png,image/jpeg,image/webp,image/svg+xml"
  onchange={onImageInput}
  bind:this={fileInput}
  hidden
/>

{#if open && popoverPos}
  <div
    bind:this={popoverEl}
    class="popover"
    class:wide={stage === "emoji"}
    role="menu"
    style="top: {popoverPos.top}px; left: {popoverPos.left}px;"
  >
    {#if stage === "menu"}
      <button class="item" type="button" onclick={() => (stage = "emoji")}>
        <span class="item-icon"><Smile weight="fill" size={16} /></span>
        <span class="item-label">Pick emoji</span>
        <span class="chev">›</span>
      </button>
      <button class="item" type="button" onclick={pickImageClick}>
        <span class="item-icon"><ImagePlus weight="fill" size={16} /></span>
        <span class="item-label">Upload image…</span>
      </button>
      <button class="item" type="button" onclick={pickInitials}>
        <span class="item-icon"><Type weight="fill" size={16} /></span>
        <span class="item-label">Use initials</span>
      </button>
      {#if error}<div class="err">{error}</div>{/if}
    {:else}
      <div class="emoji-host">
        <EmojiPicker onpick={pickEmoji} />
      </div>
    {/if}
  </div>
{/if}

<style>
  .trigger {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 14px;
    color: var(--color-fg);
    cursor: pointer;
    padding: 0;
    overflow: hidden;
    transition: border-color 0.12s, transform 0.08s;
  }
  .trigger:hover { border-color: var(--color-border-strong); }
  .trigger:active { transform: scale(0.97); }
  .trigger:disabled { opacity: 0.6; cursor: default; }
  .trigger .img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .trigger .emoji {
    font-size: 32px;
    line-height: 1;
  }
  .trigger .initials {
    font-size: 18px;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  .popover {
    position: fixed;
    z-index: 2147483646;
    width: 240px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    box-shadow: var(--shadow-pop);
    padding: 0.35rem;
    color: var(--color-fg);
    animation: pop-in 0.12s ease-out;
  }
  .popover.wide { width: 340px; padding: 0; }

  @keyframes pop-in {
    from { opacity: 0; transform: translateY(-4px); }
    to { opacity: 1; transform: translateY(0); }
  }

  .item {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    width: 100%;
    padding: 0.5rem 0.6rem;
    background: transparent;
    border: 0;
    border-radius: 7px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    text-align: left;
    cursor: pointer;
  }
  .item:hover { background: var(--color-surface-soft); }
  .item-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .item-label { flex: 1 1 auto; }
  .chev { color: var(--color-fg-subtle); font-size: 1rem; }

  .err {
    margin: 0.4rem 0.4rem 0.2rem;
    font-size: 0.75rem;
    color: #ef4444;
  }

  .emoji-host { padding: 0; }
</style>
