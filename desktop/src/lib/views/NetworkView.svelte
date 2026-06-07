<script lang="ts">
  /**
   * NetworkView — the social surface. A destination chip rail plus a
   * feed, matching the old NetworkPanel's shape. Per-handle accent comes
   * from the personalColor system. Posting/follow wiring is deferred.
   */
  import { personalColor } from "$lib/personalColor";
  import { auth } from "$lib/auth.svelte";

  const chips = ["All", "Inbox", "Friends", "Groups", "Subs"];
  let active = $state("All");

  const feed = [
    { handle: "ada", avatar: "🟣", body: "Shipped a new workbook on supply chains." },
    { handle: "grace", avatar: "🛰️", body: "Forked the climate board — added a column." },
  ];
</script>

<section class="net">
  <nav class="chips">
    {#each chips as c (c)}
      <button class="chip" class:active={active === c} onclick={() => (active = c)}>{c}</button>
    {/each}
  </nav>

  {#if !auth.signedIn}
    <p class="hint">Sign in to post and follow. Browsing works either way.</p>
  {/if}

  <div class="feed">
    {#each feed as p (p.handle)}
      {@const col = personalColor(p.handle, p.avatar)}
      <article class="post">
        <span class="avatar" style="border-color: {col.ring}; background: {col.fill}">{p.avatar}</span>
        <div class="body">
          <span class="handle">@{p.handle}</span>
          <p>{p.body}</p>
        </div>
      </article>
    {/each}
  </div>
</section>

<style>
  .net {
    max-width: 600px;
    margin: 0 auto;
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
  }
  .chips {
    display: flex;
    gap: 0.35rem;
    flex-wrap: wrap;
  }
  .chip {
    height: 28px;
    padding: 0 0.7rem;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    cursor: pointer;
  }
  .chip.active {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: transparent;
  }
  .hint {
    font-size: 0.8rem;
    color: var(--color-fg-muted);
    margin: 0;
  }
  .feed {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .post {
    display: flex;
    gap: 0.6rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    padding: 0.7rem 0.8rem;
  }
  .avatar {
    flex-shrink: 0;
    width: 32px;
    height: 32px;
    border-radius: 999px;
    border: 1.5px solid var(--color-border);
    display: grid;
    place-items: center;
    font-size: 1rem;
  }
  .body {
    min-width: 0;
  }
  .handle {
    font-size: 0.8rem;
    font-weight: 600;
  }
  .body p {
    margin: 0.15rem 0 0;
    font-size: 0.85rem;
    color: var(--color-fg);
  }
</style>
