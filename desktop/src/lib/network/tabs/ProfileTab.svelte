<script lang="ts">
  /**
   * ProfileTab — my hero + my published work.
   *
   * Identity comes from loadIdentity() at mount; the "Published" grid
   * is empty until the Broker exposes GET /v1/network/shares?from=me.
   */
  import { onMount } from "svelte";
  import ProfileHero from "../components/ProfileHero.svelte";
  import PreviewPane from "../components/PreviewPane.svelte";
  import EmptyState from "../components/EmptyState.svelte";
  import { loadIdentity } from "$lib/bridge/network.svelte";
  import type { Artifact, Person } from "../types";

  let preview = $state<Artifact | null>(null);
  let me = $state<Person | null>(null);
  let loading = $state(true);

  onMount(async () => {
    try {
      const id = await loadIdentity();
      if (id) {
        // Map IdentityView → minimal Person. Bio/avatar/network list
        // need real Broker fields when those endpoints exist.
        me = {
          handle: id.handle ?? "(unknown)",
          displayName: id.handle ?? "you",
          avatar: "👤",
          bio: "",
          did: id.did,
          verified: false,
          publishedCount: 0,
          networkIds: [],
        };
      }
    } catch {
      // Sidecar unreachable — me stays null, empty state renders.
    } finally {
      loading = false;
    }
  });
</script>

<div class="wrap">
  {#if me}
    <ProfileHero person={me} isMe />

    <section class="section">
      <header class="section-head">
        <h2>Published</h2>
        <span class="count">0</span>
      </header>

      <EmptyState
        title="Nothing published yet"
        blurb="When you publish a workbook from your workspace, it shows up here. Live counts wire up when the Broker exposes a per-user share listing."
        glyph="✦"
        hue={190}
      />
    </section>
  {:else if !loading}
    <EmptyState
      title="Not connected"
      blurb="Connect to Workhorse to see your profile. The Connect button is in the top-right of the Network panel."
      glyph="◌"
    />
  {/if}
</div>

{#if preview}
  <PreviewPane artifact={preview} onclose={() => (preview = null)} />
{/if}

<style>
  .wrap {
    display: flex;
    flex-direction: column;
    gap: 1.4rem;
    max-width: 760px;
    margin: 0 auto;
  }
  .section-head {
    display: flex;
    align-items: baseline;
    gap: 0.5rem;
    margin-bottom: 0.6rem;
  }
  .section-head h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .section-head .count {
    color: var(--color-fg-subtle);
    font-size: 0.85rem;
    font-variant-numeric: tabular-nums;
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 0.75rem;
  }
</style>
