<script lang="ts">
  /**
   * Component workbench (/dev) — render components in isolation with live
   * controls, so UI iteration doesn't require booting the whole app. Tiny
   * module graph → fast, and immune to the HMR wedges that hit the full app.
   *
   * Add a story by appending to STORIES. Each story owns its own controls
   * (kept inline for now; promote to a shared control kit if this grows).
   */
  import FolderIcon from "$lib/ui/FolderIcon.svelte";

  const STORIES = ["FolderIcon"] as const;
  let story = $state<(typeof STORIES)[number]>("FolderIcon");

  // ── FolderIcon controls ──
  let icon = $state("📋");
  let color = $state("#9a9a9e");
  let size = $state(56);
  const PRESETS: { label: string; value: string }[] = [
    { label: "Gray", value: "#9a9a9e" },
    { label: "Mac blue", value: "#6e9ad6" },
    { label: "Green", value: "#6fae84" },
    { label: "Amber", value: "#d9a441" },
    { label: "Slate", value: "#6b7280" },
  ];
  const SIZES = [24, 31, 40, 56, 80];
  // A small rail strip to preview real context (apps = bare, folders = folder).
  const RAIL = [
    { kind: "app", icon: "📋", name: "Kanban" },
    { kind: "app", icon: "📝", name: "Notes" },
    { kind: "folder", icon: "💼", name: "Clients" },
    { kind: "app", icon: "📈", name: "Tracker" },
    { kind: "folder", icon: "🚀", name: "Side Projects" },
  ] as const;
</script>

<div class="wb">
  <aside class="stories">
    <h1>Workbench</h1>
    <nav>
      {#each STORIES as s}
        <button class:active={story === s} onclick={() => (story = s)}>{s}</button>
      {/each}
    </nav>
    <p class="hint">Isolated component preview. Edits hot-reload instantly here.</p>
  </aside>

  <main class="canvas">
    {#if story === "FolderIcon"}
      <section class="controls">
        <label>
          <span>Icon</span>
          <input bind:value={icon} placeholder="emoji or empty" />
        </label>
        <label>
          <span>Color</span>
          <input type="color" bind:value={color} />
        </label>
        <div class="presets">
          {#each PRESETS as p}
            <button
              class="chip"
              class:on={color.toLowerCase() === p.value.toLowerCase()}
              style="--sw:{p.value}"
              onclick={() => (color = p.value)}>{p.label}</button
            >
          {/each}
        </div>
        <label class="range">
          <span>Size {size}px</span>
          <input type="range" min="20" max="120" bind:value={size} />
        </label>
      </section>

      <section class="stage">
        <div class="big light">
          <FolderIcon {color} {size} />
          <span class="cap">light</span>
        </div>
        <div class="big dark">
          <FolderIcon {color} {size} />
          <span class="cap">dark</span>
        </div>
      </section>

      <section class="row">
        <h2>Sizes</h2>
        <div class="sizes">
          {#each SIZES as s}
            <div class="szcell">
              <FolderIcon {color} size={s} />
              <span class="cap">{s}</span>
            </div>
          {/each}
        </div>
      </section>

      <section class="row">
        <h2>Rail context — apps (bare) vs folders</h2>
        <div class="rail-strip">
          {#each RAIL as it}
            <div class="rail-cell" title={it.name}>
              {#if it.kind === "folder"}
                <FolderIcon {color} size={31} />
              {:else}
                <span class="bare">{it.icon}</span>
              {/if}
            </div>
          {/each}
        </div>
        <p class="hint">The strip uses the live color so you can judge folders next to bare apps at rail size (31px).</p>
      </section>
    {/if}
  </main>
</div>

<style>
  .wb {
    position: fixed;
    inset: 0;
    display: grid;
    grid-template-columns: 200px 1fr;
    font-family: var(--font, system-ui, sans-serif);
    background: var(--color-page, #fafafa);
    color: var(--color-fg, #111);
    z-index: 9999;
  }
  .stories {
    border-right: 1px solid var(--color-border, #0001);
    padding: 16px 12px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    background: var(--color-surface, #fff);
  }
  .stories h1 {
    font-size: 13px;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--color-fg-muted, #666);
    margin: 0 0 4px;
  }
  .stories nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .stories nav button {
    text-align: left;
    border: 0;
    background: transparent;
    padding: 7px 9px;
    border-radius: 7px;
    font: inherit;
    font-size: 13px;
    color: var(--color-fg, #111);
    cursor: pointer;
  }
  .stories nav button:hover {
    background: var(--color-surface-soft, #f2f2f2);
  }
  .stories nav button.active {
    background: var(--color-fg, #111);
    color: var(--color-page, #fff);
  }
  .hint {
    font-size: 11px;
    line-height: 1.5;
    color: var(--color-fg-muted, #888);
    margin: 0;
  }
  .canvas {
    overflow-y: auto;
    padding: 22px 26px;
    display: flex;
    flex-direction: column;
    gap: 26px;
  }
  .controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 16px;
    padding: 14px 16px;
    border: 1px solid var(--color-border, #0001);
    border-radius: 12px;
    background: var(--color-surface, #fff);
  }
  .controls label {
    display: flex;
    flex-direction: column;
    gap: 5px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    color: var(--color-fg-muted, #777);
  }
  .controls input[type="text"],
  .controls input:not([type]) {
    width: 150px;
  }
  .controls input {
    font: inherit;
    padding: 6px 8px;
    border: 1px solid var(--color-border-strong, #0002);
    border-radius: 7px;
    background: var(--color-page, #fafafa);
    color: inherit;
  }
  .controls .range {
    min-width: 180px;
  }
  .presets {
    display: flex;
    gap: 6px;
    align-self: flex-end;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: 1px solid var(--color-border-strong, #0002);
    background: var(--color-surface, #fff);
    border-radius: 999px;
    padding: 5px 10px 5px 8px;
    font: inherit;
    font-size: 12px;
    cursor: pointer;
    color: inherit;
  }
  .chip::before {
    content: "";
    width: 11px;
    height: 11px;
    border-radius: 3px;
    background: var(--sw);
    box-shadow: 0 0 0 1px #0002 inset;
  }
  .chip.on {
    border-color: var(--color-fg, #111);
  }
  .stage {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
  }
  .big {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    height: 220px;
    border-radius: 14px;
    border: 1px solid var(--color-border, #0001);
  }
  .big.light {
    background: #fafafa;
    color: #111;
  }
  .big.dark {
    background: #1a1a1f;
    color: #f4f4f5;
  }
  .cap {
    font-size: 11px;
    opacity: 0.6;
  }
  .row h2 {
    font-size: 13px;
    font-weight: 600;
    margin: 0 0 12px;
  }
  .sizes {
    display: flex;
    align-items: flex-end;
    gap: 26px;
  }
  .szcell {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }
  .rail-strip {
    display: inline-flex;
    flex-direction: column;
    gap: 8px;
    align-items: center;
    width: 56px;
    padding: 12px 0;
    border: 1px solid var(--color-border, #0001);
    border-radius: 12px;
    background: var(--color-surface, #fff);
  }
  .rail-cell {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border-radius: 10px;
  }
  .rail-cell:hover {
    background: var(--color-surface-soft, #f2f2f2);
  }
  .bare {
    font-size: 19px;
    line-height: 1;
  }
</style>
