<script>
  import { onMount } from 'svelte';
  import { sharedFolders, shareFolder, addSharedFolder, revokeShare } from '$lib/api.js';
  import { workspaceStore } from '$lib/workspaceStore.svelte.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';

  // Sharing at the workspace level: guests (folders shared with named people) and
  // the workspace's public/private posture. Backed by the shared-folders seam
  // (api.js → runtime /api/shared-folders); honest empty until a runtime is wired.
  const wsName = $derived(workspaceStore.active?.name || 'this workspace');

  let data = $state({ shareable: [], shared_by: [], shared_with: [] });
  let loading = $state(true);

  // visibility posture — private by default; honest local toggle until the
  // control-plane visibility endpoint lands.
  let visibility = $state('private');

  let shareOpen = $state(false);
  let pickFolder = $state('');
  let recipient = $state('');
  let mode = $state('read');
  let revokeFor = $state(null);
  let busy = $state(null);

  async function load() {
    loading = true;
    data = await sharedFolders();
    if (!pickFolder) pickFolder = data.shareable[0] || '';
    loading = false;
  }
  onMount(load);

  const MODE_STYLE = {
    read: 'background:var(--sky);color:var(--on-bloom);border-color:var(--sky)',
    draft: 'background:var(--mint);color:var(--on-bloom);border-color:var(--mint)'
  };
  const modeLabel = (m) => (m === 'draft' ? 'Can edit (Draft)' : 'View only');

  async function doShare() {
    if (!pickFolder || !recipient.trim()) { toast('Pick a folder and a guest'); return; }
    const g = await shareFolder({ folder: pickFolder, recipient: recipient.trim(), mode });
    data.shared_by = [g, ...data.shared_by];
    shareOpen = false; recipient = '';
    toast(`Shared “${g.folder}” with ${g.recipient}`);
  }

  async function add(g) {
    busy = g.id;
    const r = await addSharedFolder(g.id);
    busy = null;
    data.shared_with = data.shared_with.map((s) => (s.id === g.id ? { ...s, added: true } : s));
    toast(`Added “${r.folder}” to ${wsName} · ${r.files.length} files`);
  }

  async function reallyRevoke() {
    const g = revokeFor;
    revokeFor = null;
    busy = g.id;
    await revokeShare(g.id);
    busy = null;
    data.shared_by = data.shared_by.filter((s) => s.id !== g.id);
    toast(`Stopped sharing “${g.folder}”`, 'bad');
  }
</script>

<!-- visibility posture -->
<div class="card" style="display:flex;align-items:center;gap:16px">
  <div style="flex:1">
    <b style="font-size:13.5px">Visibility</b>
    <div class="faint" style="font-size:11.5px">
      {visibility === 'public'
        ? `${wsName} is public — anyone with the link can view.`
        : `${wsName} is private — only members and named guests have access.`}
    </div>
  </div>
  <div class="seg vis">
    <button class:on={visibility === 'private'} onclick={() => { visibility = 'private'; toast('Workspace is private'); }}>Private</button>
    <button class:on={visibility === 'public'} onclick={() => { visibility = 'public'; toast('Workspace is public'); }}>Public</button>
  </div>
</div>

{#if loading}
  <div class="card" style="color:var(--dim);text-align:center">Loading…</div>
{:else}
  <!-- shared WITH this workspace -->
  <div class="grphead">
    <h3 class="grp">Shared with {wsName}</h3>
  </div>
  {#if data.shared_with.length === 0}
    <div class="card faint" style="text-align:center">No one has shared a folder with this workspace yet.</div>
  {:else}
    <div class="cards">
      {#each data.shared_with as g (g.id)}
        <div class="card fcard">
          <div class="ftop">
            <span class="fic">📁</span>
            <div class="fmeta">
              <div class="fname">{g.folder}</div>
              <div class="faint mono" style="font-size:11.5px">from {g.owner}</div>
            </div>
            <span class="tag" style={MODE_STYLE[g.mode]}>{modeLabel(g.mode)}</span>
          </div>
          <div class="ffoot">
            {#if g.added}
              <span class="dim" style="font-size:12.5px">✓ In {wsName}</span>
            {:else}
              <button class="btn sm primary" onclick={() => add(g)} disabled={busy === g.id}>
                {busy === g.id ? 'Adding…' : 'Add to workspace'}
              </button>
            {/if}
          </div>
        </div>
      {/each}
    </div>
  {/if}

  <!-- guests this workspace shares OUT -->
  <div class="grphead" style="margin-top:26px">
    <h3 class="grp">Guests</h3>
    <button class="btn sm primary" onclick={() => (shareOpen = true)} disabled={!data.shareable.length}>
      <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Invite a guest
    </button>
  </div>
  {#if data.shared_by.length === 0}
    <div class="card faint" style="text-align:center">No guests yet. Share a folder to collaborate with someone outside this workspace.</div>
  {:else}
    <div class="cards">
      {#each data.shared_by as g (g.id)}
        <div class="card fcard">
          <div class="ftop">
            <span class="fic">📁</span>
            <div class="fmeta">
              <div class="fname">{g.folder}</div>
              <div class="faint mono" style="font-size:11.5px">with {g.recipient}</div>
            </div>
            <span class="tag" style={MODE_STYLE[g.mode]}>{modeLabel(g.mode)}</span>
          </div>
          <div class="ffoot">
            <button class="btn sm" onclick={() => (revokeFor = g)} disabled={busy === g.id}>Remove access</button>
          </div>
        </div>
      {/each}
    </div>
  {/if}
{/if}

{#if shareOpen}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) shareOpen = false; }}>
    <div class="sheet" style="width:460px">
      <h2>Invite a guest</h2>
      <p class="sub">The guest gets their own copy. Their edits become Drafts — your folder is never changed by them.</p>

      <div class="lab">Folder</div>
      <div class="regions">
        {#each data.shareable as f}
          <div class="reg" role="button" tabindex="0" class:sel={pickFolder === f}
               onclick={() => (pickFolder = f)} onkeydown={(e) => { if (e.key === 'Enter') pickFolder = f; }}>{f}</div>
        {/each}
      </div>

      <div class="lab">Guest</div>
      <div class="field"><input type="text" placeholder="name or email" bind:value={recipient} /></div>

      <div class="lab">They can</div>
      <div class="regions">
        <div class="reg" role="button" tabindex="0" class:sel={mode === 'read'} style={mode === 'read' ? MODE_STYLE.read : ''} onclick={() => (mode = 'read')} onkeydown={() => {}}>View only</div>
        <div class="reg" role="button" tabindex="0" class:sel={mode === 'draft'} style={mode === 'draft' ? MODE_STYLE.draft : ''} onclick={() => (mode = 'draft')} onkeydown={() => {}}>Edit as Draft</div>
      </div>

      <div class="sheet-foot">
        <button class="btn" type="button" onclick={() => (shareOpen = false)}>Cancel</button>
        <button class="btn primary" type="button" onclick={doShare}>Share folder</button>
      </div>
    </div>
  </div>
{/if}

<Confirm
  open={!!revokeFor}
  title="Remove this guest's access?"
  body={revokeFor ? `${revokeFor.recipient} will lose access to “${revokeFor.folder}”. A copy they already added stays in their own workspace.` : ''}
  confirmLabel="Remove access"
  danger
  onconfirm={reallyRevoke}
  oncancel={() => (revokeFor = null)}
/>

<style>
  .grphead { display:flex; align-items:center; justify-content:space-between; margin:0 0 10px; }
  .grp { font-size:13px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; margin:0; font-weight:700; }
  .cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:12px; }
  .fcard { display:flex; flex-direction:column; gap:14px; }
  .ftop { display:flex; align-items:center; gap:11px; }
  .fic { font-size:22px; flex:none; }
  .fmeta { flex:1; min-width:0; }
  .fname { font-weight:650; font-size:14.5px; }
  .ffoot { display:flex; justify-content:flex-end; border-top:1px solid var(--line); padding-top:11px; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
  .seg { display:flex; border:2px solid var(--stroke); border-radius:9px; overflow:hidden; flex:none; }
  .seg button { padding:6px 16px; font:600 11px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); background:var(--card); cursor:pointer; border:none; }
  .seg button.on { background:var(--ink); color:var(--paper); }
</style>
