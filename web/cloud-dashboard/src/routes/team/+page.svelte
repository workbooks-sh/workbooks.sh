<script>
  import WorkOSWidget from '$lib/WorkOSWidget.svelte';
  import { toast } from '$lib/toastStore.svelte.js';
  let { data } = $props();
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Team</h2>
      <p>Members of the <b>{data.org}</b> workspace. Invites, roles &amp; removals are handled entirely by WorkOS — the panel below is the live User Management widget.</p>
    </div>
  </div>

  <!-- seat-usage strip -->
  <div class="card" style="display:flex;align-items:center;gap:18px">
    <div style="flex:1">
      <div style="display:flex;justify-content:space-between;font-size:13px"><span><b>Team</b> plan · 3 of 10 seats used</span><span class="dim mono">7 seats left</span></div>
      <div class="bar"><i style="width:30%"></i></div>
      <div class="faint" style="font-size:11.5px">Seats sync automatically — adding a member bumps your Polar subscription; removing one drops it.</div>
    </div>
    <button class="btn sm" onclick={() => toast('Upgrade flow opening…')}>Upgrade plan</button>
  </div>

  <!-- WorkOS User Management widget (live, embedded) -->
  <div class="card" style="padding:0;overflow:hidden">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:1px solid var(--line)">
      <div style="display:flex;align-items:center;gap:8px">
        <svg class="ico" viewBox="0 0 24 24" style="width:13px;height:13px"><path fill="var(--faint)" d="M12 1l9 4v6c0 5-3.8 9.7-9 11-5.2-1.3-9-6-9-11V5l9-4Z"/></svg>
        <span class="faint" style="font-size:11.5px">WorkOS · User Management widget</span>
      </div>
    </div>
    <div style="padding:4px">
      {#if data.authToken}
        <WorkOSWidget authToken={data.authToken} />
      {:else}
        <div style="padding:24px">
          <p>Couldn't mint the widget token.</p>
          <p class="muted">{data.error}</p>
        </div>
      {/if}
    </div>
  </div>

  <div class="note">Enterprise workspaces also get the WorkOS <b>Admin Portal</b> widgets here for self-serve SSO + SCIM/Directory Sync — gated by plan.</div>
</section>
