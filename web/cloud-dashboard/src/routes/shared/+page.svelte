<script>
  import { onMount } from 'svelte';
  import { sharedFolders, shareFolder, addSharedFolder, revokeShare } from '$lib/api.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';

  let data = $state({ shareable: [], shared_by: [], shared_with: [] });
  let loading = $state(true);

  let shareOpen = $state(false);
  let pickFolder = $state('');
  let recipient = $state('');
  let mode = $state('read');
  let revokeFor = $state(null);
  let busy = $state(null);            // id currently adding/revoking

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
    if (!pickFolder || !recipient.trim()) { toast('Pick a folder and a teammate'); return; }
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
    toast(`Added “${r.folder}” to your workspace · ${r.files.length} files`);
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

<section>
  <div class="sechead">
    <div>
      <h2>Shared folders</h2>
      <p>Share a folder with a teammate, or add a folder they’ve shared into your own workspace. Edits you make to a shared folder are saved as a Draft — nothing is ever overwritten.</p>
    </div>
    <button class="btn primary" onclick={() => (shareOpen = true)} disabled={!data.shareable.length}>
      <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Share a folder
    </button>
  </div>

  {#if loading}
    <div class="card" style="color:var(--dim);text-align:center">Loading…</div>
  {:else}
    <!-- shared WITH you -->
    <h3 class="grp">Shared with you</h3>
    {#if data.shared_with.length === 0}
      <div class="card faint" style="text-align:center">No one has shared a folder with you yet.</div>
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
                <span class="dim" style="font-size:12.5px">✓ In your workspace</span>
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

    <!-- you're sharing -->
    <h3 class="grp" style="margin-top:26px">You’re sharing</h3>
    {#if data.shared_by.length === 0}
      <div class="card faint" style="text-align:center">You’re not sharing any folders. Share one to collaborate with a teammate.</div>
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
              <button class="btn sm" onclick={() => (revokeFor = g)} disabled={busy === g.id}>Stop sharing</button>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  {/if}
</section>

{#if shareOpen}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) shareOpen = false; }}>
    <div class="sheet" style="width:460px">
      <h2>Share a folder</h2>
      <p class="sub">The teammate gets their own copy in their workspace. Their edits become Drafts — your folder is never changed by them.</p>

      <div class="lab">Folder</div>
      <div class="regions">
        {#each data.shareable as f}
          <div class="reg" role="button" tabindex="0" class:sel={pickFolder === f}
               onclick={() => (pickFolder = f)} onkeydown={(e) => { if (e.key === 'Enter') pickFolder = f; }}>{f}</div>
        {/each}
      </div>

      <div class="lab">Teammate</div>
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
  title="Stop sharing this folder?"
  body={revokeFor ? `${revokeFor.recipient} will lose access to “${revokeFor.folder}”. A copy they already added stays in their workspace as their own.` : ''}
  confirmLabel="Stop sharing"
  danger
  onconfirm={reallyRevoke}
  oncancel={() => (revokeFor = null)}
/>

<style>
  .grp { font-size:13px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; margin:0 0 10px; font-weight:700; }
  .cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:12px; }
  .fcard { display:flex; flex-direction:column; gap:14px; }
  .ftop { display:flex; align-items:center; gap:11px; }
  .fic { font-size:22px; flex:none; }
  .fmeta { flex:1; min-width:0; }
  .fname { font-weight:650; font-size:14.5px; }
  .ffoot { display:flex; justify-content:flex-end; border-top:1px solid var(--line); padding-top:11px; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
</style>
