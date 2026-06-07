<script lang="ts">
  /**
   * FeedTab — single centered column, Twitter-style.
   *
   * Currently always empty in production: there is no cross-network
   * "feed" endpoint on the Broker yet — only direct shares (Inbox),
   * subscriptions (Subscriptions tab), and forks (per-fork upstream
   * watching). When a feed endpoint lands this loader wires up.
   */
  import EmptyState from "../components/EmptyState.svelte";

  let { networkId = null }: { networkId?: string | null } = $props();
</script>

<div class="column">
  <EmptyState
    title="Feed not available yet"
    blurb="A cross-network activity feed lands when the Broker exposes one. For now, check Inbox for direct shares and Subscriptions for things you follow."
    glyph="✷"
    hue={35}
  />
</div>

<style>
  .column {
    width: 100%;
    max-width: 620px;
    margin: 0 auto;
  }
  .stream {
    display: flex;
    flex-direction: column;
  }
</style>
