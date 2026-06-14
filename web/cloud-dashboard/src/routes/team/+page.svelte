<script>
  import WorkOSWidget from '$lib/WorkOSWidget.svelte';
  import { toast } from '$lib/toastStore.svelte.js';
  let { data } = $props();
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Team</h2>
      <p>Members of {data.workspace ? `the ${data.workspace}` : 'your'} workspace. Invite teammates, assign roles, and manage who can access your nexuses.</p>
    </div>
  </div>

  <!-- seat usage -->
  <div class="card" style="display:flex;align-items:center;gap:18px">
    <div style="flex:1">
      <div style="display:flex;justify-content:space-between;font-size:13px"><span><b>Team</b> plan · 3 of 10 seats used</span><span class="dim mono">7 seats left</span></div>
      <div class="bar"><i style="width:30%"></i></div>
      <div class="faint" style="font-size:11.5px">Seats update automatically as you add or remove members.</div>
    </div>
    <button class="btn sm" onclick={() => toast('Upgrade flow opening…')}>Upgrade plan</button>
  </div>

  <!-- members -->
  <div class="card" style="padding:4px">
    {#if data.authToken}
      <WorkOSWidget authToken={data.authToken} />
    {:else}
      <div style="padding:24px">
        <p>The team panel is unavailable right now.</p>
        <p class="muted">Please try again in a moment.</p>
      </div>
    {/if}
  </div>
</section>
