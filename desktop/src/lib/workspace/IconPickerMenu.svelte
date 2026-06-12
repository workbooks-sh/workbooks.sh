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
  import { tick } from "svelte";
  import { ImageSquare as ImagePlus, TextT as Type } from "phosphor-svelte";
  import Icon from "$lib/ui/Icon.svelte";
  import {
    materialIconUrl,
    searchMaterialIcons,
  } from "$lib/ui/materialIcon";

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

  let open = $state(false);
  let triggerEl = $state<HTMLButtonElement | null>(null);
  let popoverEl = $state<HTMLDivElement | null>(null);
  let popoverPos = $state<{ top: number; left: number } | null>(null);
  let fileInput = $state<HTMLInputElement | null>(null);
  let searchEl = $state<HTMLInputElement | null>(null);
  let busy = $state(false);
  let error = $state<string | null>(null);

  // ── one search over the universal icon library ───────────────────
  // Material icons by def name + emoji (emoji-picker-element's search
  // database) in a single result grid.
  let query = $state("");
  /** Curated starter grid shown before the user types. */
  const STARTER_DEFS = [
    "todo", "document", "readme", "table", "database", "settings",
    "rocket", "lib", "zip", "email", "image", "video",
    "audio", "pdf", "markdown", "json", "html", "css",
    "javascript", "typescript", "python", "rust", "go", "java",
  ];
  const matResults = $derived(
    query.trim()
      ? searchMaterialIcons(query, 48)
      : STARTER_DEFS.map((def) => ({ def, url: materialIconUrl(def)! })).filter(
          (x) => x.url,
        ),
  );

  type EmojiHit = { unicode: string; annotation: string };
  let emojiResults = $state<EmojiHit[]>([]);
  let emojiDb: { getEmojiBySearchQuery(q: string): Promise<unknown[]> } | null =
    null;
  $effect(() => {
    const q = query.trim();
    if (!q || q.length < 2) {
      emojiResults = [];
      return;
    }
    let cancelled = false;
    void (async () => {
      try {
        if (!emojiDb) {
          const { default: Database } = await import(
            "emoji-picker-element/database"
          );
          emojiDb = new Database();
        }
        const hits = (await emojiDb.getEmojiBySearchQuery(q)) as {
          unicode?: string;
          annotation?: string;
        }[];
        if (!cancelled) {
          emojiResults = hits
            .filter((h) => h.unicode)
            .slice(0, 24)
            .map((h) => ({ unicode: h.unicode!, annotation: h.annotation ?? "" }));
        }
      } catch {
        if (!cancelled) emojiResults = [];
      }
    })();
    return () => {
      cancelled = true;
    };
  });

  function pickMaterial(def: string) {
    value = `mi:${def}`;
    open = false;
  }

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
    query = "";
    open = true;
    error = null;
    await positionPopover();
    searchEl?.focus();
  }

  async function positionPopover() {
    await tick();
    if (!triggerEl) return;
    const r = triggerEl.getBoundingClientRect();
    const popW = 340;
    const popH = 400;
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
    <!-- Shared resolver: handles glyph values (lucide:<Name>) as well as
         plain emoji — a raw {value} printed the literal "lucide:…" string. -->
    <span class="emoji" aria-hidden="true">
      <Icon {value} {name} size={Math.round(size * 0.5)} />
    </span>
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
    class="popover wide"
    role="menu"
    style="top: {popoverPos.top}px; left: {popoverPos.left}px;"
  >
    <input
      bind:this={searchEl}
      bind:value={query}
      class="search"
      type="text"
      placeholder="Search icons & emoji…"
      spellcheck="false"
    />
    <div class="grid-scroll">
      {#if matResults.length === 0 && emojiResults.length === 0}
        <p class="none">No matches</p>
      {:else}
        <div class="icon-grid">
          {#each matResults as m (m.def)}
            <button
              type="button"
              class="cell"
              title={m.def}
              onclick={() => pickMaterial(m.def)}
            >
              <img src={m.url} alt={m.def} loading="lazy" />
            </button>
          {/each}
          {#each emojiResults as em (em.unicode)}
            <button
              type="button"
              class="cell"
              title={em.annotation}
              onclick={() => pickEmoji(em.unicode)}
            >
              <span class="em">{em.unicode}</span>
            </button>
          {/each}
        </div>
      {/if}
    </div>
    <div class="foot">
      <button class="foot-btn" type="button" onclick={pickImageClick}>
        <ImagePlus weight="fill" size={13} /> Image…
      </button>
      <button class="foot-btn" type="button" onclick={pickInitials}>
        <Type weight="fill" size={13} /> Initials
      </button>
      {#if error}<span class="err">{error}</span>{/if}
    </div>
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
    transition: border-color 0.15s, transform 0.08s;
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
    border-radius: var(--radius-lg);
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

  .search {
    width: 100%;
    box-sizing: border-box;
    padding: 7px 10px;
    margin-bottom: 6px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    outline: none;
  }
  .search:focus { border-color: var(--color-border-strong); }

  .grid-scroll {
    max-height: 280px;
    overflow-y: auto;
  }
  .icon-grid {
    display: grid;
    grid-template-columns: repeat(8, 1fr);
    gap: 2px;
  }
  .cell {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    aspect-ratio: 1;
    border: 0;
    border-radius: 8px;
    background: transparent;
    cursor: pointer;
    padding: 0;
    transition: background 0.15s;
  }
  .cell:hover { background: var(--color-surface-soft); }
  .cell img {
    width: 20px;
    height: 20px;
    display: block;
  }
  .cell .em {
    font-size: 18px;
    line-height: 1;
  }
  .none {
    margin: 1.2rem 0;
    text-align: center;
    font-size: 0.8rem;
    color: var(--color-fg-muted);
  }

  .foot {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 6px;
    padding-top: 6px;
    border-top: 1px solid var(--color-border);
  }
  .foot-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 9px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: transparent;
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 11px;
    cursor: pointer;
    transition: color 0.15s, border-color 0.15s;
  }
  .foot-btn:hover { color: var(--color-fg); border-color: var(--color-border-strong); }

  .err {
    margin-left: auto;
    font-size: 0.72rem;
    color: var(--color-err);
  }
</style>
