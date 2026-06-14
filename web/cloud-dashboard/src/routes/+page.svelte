<script>
  import WorkOSWidget from '$lib/WorkOSWidget.svelte';
  let { data } = $props();
</script>

<main class="wrap">
  <header>
    <h1>Team</h1>
    <p>Members of your workspace — invites, roles &amp; removals are handled entirely by WorkOS. The panel below is the live User Management widget.</p>
  </header>

  <div class="card">
    {#if data.authToken}
      <WorkOSWidget authToken={data.authToken} />
    {:else}
      <div style="padding:24px">
        <p>Couldn't mint the widget token.</p>
        <p class="muted">{data.error}</p>
      </div>
    {/if}
  </div>
  <p class="muted" style="margin-top:14px">workspace · {data.org} · seats auto-sync to Polar on membership change</p>
</main>
