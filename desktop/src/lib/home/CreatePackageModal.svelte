<script lang="ts">
  /**
   * CreatePackageModal — name + icon for a new Package (wb-i38o.35).
   *
   * Two operating modes, picked by the user up-stream in the popover:
   *
   *   * `create` — empty package; back-end calls package_create
   *   * `import` — `sourcePath` recursively copied into the monorepo
   *                at ~/Workbooks/monorepo/workspaces/<ws>/<pkg>/
   *                via package_import_folder
   *
   * Mirrors WorkspaceOnboarding's shape: emoji picker + name input +
   * primary submit. The two modes share one component because the
   * UX is identical apart from a "Source folder" line under the title
   * when importing.
   */
  import { Check } from "phosphor-svelte";
  import IconPickerMenu from "$lib/workspace/IconPickerMenu.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import {
    basenameFromPath,
    type CreatePackageModalState,
  } from "./createPackage.svelte";

  let {
    data,
    onclose,
  }: {
    data: CreatePackageModalState;
    onclose: () => void;
  } = $props();

  let name = $state(data.sourcePath ? basenameFromPath(data.sourcePath) : "");
  let icon = $state("📦");
  let busy = $state(false);
  let error = $state<string | null>(null);

  const title = $derived(
    data.mode === "import" ? "Import folder as package" : "New package",
  );

  async function submit() {
    const n = name.trim();
    if (!n) return;
    const wsActive = workspaces.active;
    if (!wsActive) {
      error = "No active workspace.";
      return;
    }
    busy = true;
    error = null;
    try {
      if (data.mode === "import" && data.sourcePath) {
        await packageStore.importFolder(wsActive.name, n, data.sourcePath, icon);
      } else {
        await packageStore.create(n, icon);
      }
      await packageStore.setActive(n);
      await workspaces.addPackage(wsActive.id, n);
      chrome.openFiles();
      onclose();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }
</script>

<button
  class="backdrop"
  aria-label="Close"
  onclick={onclose}
></button>
<div class="centerer">
<div class="card" role="dialog" aria-modal="true" aria-label={title}>
  <div class="icon-row">
    <IconPickerMenu bind:value={icon} name={name || title} size={72} />
  </div>

  <h2>{title}</h2>
  {#if data.mode === "import" && data.sourcePath}
    <p class="path">Copying from <code>{data.sourcePath}</code></p>
  {:else}
    <p class="sub">Pick a name and icon. The package starts empty.</p>
  {/if}

  <form onsubmit={(e) => { e.preventDefault(); void submit(); }}>
    <input
      type="text"
      placeholder="my-package"
      bind:value={name}
      autofocus
      disabled={busy}
    />
    <div class="actions">
      <button
        type="button"
        class="btn ghost"
        onclick={onclose}
        disabled={busy}
      >Cancel</button>
      <button
        type="submit"
        class="btn primary"
        disabled={busy || !name.trim()}
      >
        <Check weight="bold" size={14} />
        {data.mode === "import" ? "Import" : "Create"}
      </button>
    </div>
  </form>

  {#if error}<div class="error">{error}</div>{/if}
</div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.28);
    border: 0;
    padding: 0;
    margin: 0;
    cursor: default;
    z-index: 1000;
  }
  /* Centering wrapper — NOT the card itself. The card avoids
   * `transform` because CSS `transform` on an ancestor turns
   * `position: fixed` descendants into "fixed relative to that
   * ancestor" instead of relative to the viewport. The icon
   * picker's popover positions itself with viewport coordinates;
   * a transformed parent would land it in the wrong place. */
  .centerer {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    pointer-events: none;
    z-index: 1001;
    padding: 16px;
  }
  .card {
    pointer-events: auto;
    width: 100%;
    max-width: 380px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.75rem 1.75rem 1.5rem;
    display: flex;
    flex-direction: column;
    text-align: center;
  }
  .icon-row {
    display: flex;
    justify-content: center;
    margin-bottom: 1rem;
  }
  h2 {
    margin: 0 0 0.4rem;
    font-size: 1rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .sub,
  .path {
    margin: 0 0 1.2rem;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    line-height: 1.5;
  }
  .path code {
    background: var(--color-surface-soft);
    padding: 1px 5px;
    border-radius: 4px;
    font-size: 0.78rem;
    word-break: break-all;
  }
  form {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.55rem 0.75rem;
    font-size: 0.92rem;
    font-family: inherit;
    color: var(--color-fg);
    outline: 0;
    text-align: center;
  }
  input:focus { border-color: var(--color-border-strong); }
  .actions {
    display: flex;
    gap: 0.5rem;
    justify-content: flex-end;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.4rem;
    height: 34px;
    padding: 0 0.85rem;
    border-radius: 8px;
    font-size: 0.84rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid transparent;
    transition: opacity 0.12s;
  }
  .btn:disabled { opacity: 0.45; cursor: default; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:not(:disabled):hover { opacity: 0.88; }
  .btn.ghost {
    background: transparent;
    border-color: var(--color-border);
    color: var(--color-fg);
  }
  .btn.ghost:not(:disabled):hover { background: var(--color-surface-soft); }
  .error {
    margin-top: 0.6rem;
    color: #ef4444;
    font-size: 0.78rem;
    word-break: break-word;
  }
</style>
