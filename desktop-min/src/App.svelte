<script lang="ts">
  /**
   * App shell — the persistent chrome around the routed views.
   *
   * Layout: a 56px vertical nav rail on the left + the routed main view.
   * RouterContext creates one router instance and hands it to both the
   * rail (for programmatic navigation) and the RouterView (which renders
   * the active route's lazy view). Sidecar/auth probe runs on mount.
   */
  import { onMount } from "svelte";
  import { RouterContext, RouterView } from "@dvcol/svelte-simple-router/components";
  import type { IRouter } from "@dvcol/svelte-simple-router/models";
  import { routerOptions } from "./router";
  import AppRail from "$lib/components/AppRail.svelte";
  import { auth } from "$lib/auth.svelte";
  import { chrome } from "$lib/chrome.svelte";

  onMount(() => {
    void auth.init();
  });
</script>

<RouterContext options={routerOptions}>
  {#snippet children(router: IRouter)}
    <div class="app">
      <AppRail {router} />
      <main class="main">
        <header class="titlebar" data-tauri-drag-region>
          <span class="pill">{chrome.section}</span>
        </header>
        <div class="view">
          <RouterView {router} />
        </div>
      </main>
    </div>
  {/snippet}
</RouterContext>

<style>
  .app {
    display: flex;
    height: 100vh;
    width: 100vw;
    overflow: hidden;
    background: var(--color-page);
  }
  .main {
    flex: 1 1 auto;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .titlebar {
    height: 36px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0 0.75rem;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface);
  }
  .pill {
    display: inline-flex;
    align-items: center;
    height: 22px;
    padding: 0 0.55rem;
    border-radius: 6px;
    font-size: 0.78rem;
    font-weight: 500;
    color: var(--color-fg);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
  }
  .view {
    flex: 1 1 auto;
    min-height: 0;
    overflow: auto;
  }
</style>
