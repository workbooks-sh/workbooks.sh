<script>
  import { onMount } from 'svelte';
  import { envStore } from '$lib/envStore.svelte.js';
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';

  // NEXUS-level secrets — the global pool for this nexus (Doppler-like). Encrypted at rest
  // (Nexus.ControlPlane.Env). Workspaces draw from / extend these with their own per-workspace
  // secrets. Scoped by a reserved "nexus:<id>" key so it never collides with a workspace's vars.
  const scope = $derived(nexusStore.active ? `nexus:${nexusStore.active.id}` : null);
  const nxName = $derived(nexusStore.active?.name || 'this nexus');

  $effect(() => { if (scope) envStore.load(scope); });
  onMount(() => { if (scope) envStore.load(scope); });

  let revealed = $state({});
  let revealBusy = $state(null);
  const timers = {};

  async function reveal(id) {
    if (revealed[id] !== undefined) return hide(id);
    revealBusy = id;
    try {
      const value = await envStore.reveal(id);
      revealed = { ...revealed, [id]: value };
      clearTimeout(timers[id]);
      timers[id] = setTimeout(() => hide(id), 30000);
    } catch { toast('Could not reveal this value', 'bad'); }
    revealBusy = null;
  }
  function hide(id) {
    clearTimeout(timers[id]);
    const { [id]: _gone, ...rest } = revealed;
    revealed = rest;
  }
  async function copy(id) {
    const v = revealed[id];
    if (v === undefined) return;
    try { await navigator.clipboard.writeText(v); toast('Copied to clipboard'); }
    catch { toast('Could not copy', 'bad'); }
  }

  let editOpen = $state(false);
  let editing = $state(null);
  let fName = $state('');
  let fValue = $state('');
  let saving = $state(false);

  function openCreate() { editing = null; fName = ''; fValue = ''; editOpen = true; }
  function openEdit(v) { editing = v; fName = v.name; fValue = ''; editOpen = true; }
  async function save() {
    if (!fName.trim()) { toast('Give the secret a name'); return; }
    saving = true;
    try {
      if (editing) {
        const attrs = { name: fName.trim() };
        if (fValue) attrs.value = fValue;
        await envStore.update(editing.id, attrs);
        toast(`Updated ${fName.trim()}`);
      } else {
        if (!fValue) { saving = false; toast('Give the secret a value'); return; }
        await envStore.create(fName.trim(), fValue);
        toast(`Added ${fName.trim()}`);
      }
      editOpen = false;
    } catch { toast('Could not save', 'bad'); }
    saving = false;
  }

  let deleteFor = $state(null);
  async function reallyDelete() {
    const v = deleteFor;
    deleteFor = null;
    hide(v.id);
    await envStore.remove(v.id);
    toast(`Removed ${v.name}`, 'bad');
  }
</script>

<div class="grphead">
  <div>
    <h3 class="grp">Nexus secrets · {nxName}</h3>
    <p class="faint" style="margin:4px 0 0;font-size:12.5px">The shared pool for this nexus — encrypted at rest, available to every workspace. Workspaces can add their own on top.</p>
  </div>
  <button class="btn sm primary" onclick={openCreate}>
    <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Add secret
  </button>
</div>

{#if envStore.loading}
  <div class="card" style="color:var(--dim);text-align:center">Loading…</div>
{:else if envStore.list.length === 0}
  <div class="card faint" style="text-align:center">
    No nexus secrets yet. Add shared keys (API tokens, connection strings) here and every workspace on {nxName} can use them.
  </div>
{:else}
  <div class="card" style="padding:0;overflow:hidden">
    <table class="env">
      <thead><tr><th>Name</th><th>Value</th><th>Created</th><th></th></tr></thead>
      <tbody>
        {#each envStore.list as v (v.id)}
          <tr>
            <td class="mono nm">{v.name}</td>
            <td class="val">
              {#if revealed[v.id] !== undefined}
                <span class="mono plain">{revealed[v.id]}</span>
                <button class="lk" onclick={() => copy(v.id)}>Copy</button>
                <button class="lk" onclick={() => hide(v.id)}>Hide</button>
              {:else}
                <span class="mono masked">{v.masked}</span>
                <span class="faint" style="font-size:11px">{v.length} chars</span>
                <button class="lk" onclick={() => reveal(v.id)} disabled={revealBusy === v.id}>
                  {revealBusy === v.id ? 'Revealing…' : 'Reveal'}
                </button>
              {/if}
            </td>
            <td class="faint" style="font-size:12px;white-space:nowrap">{v.created_at}</td>
            <td class="acts">
              <button class="lk" onclick={() => openEdit(v)}>Edit</button>
              <button class="lk danger" onclick={() => (deleteFor = v)}>Delete</button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}

{#if editOpen}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) editOpen = false; }}>
    <div class="sheet" style="width:460px">
      <h2>{editing ? 'Edit secret' : 'Add secret'}</h2>
      <p class="sub">Encrypted at rest. Shown masked everywhere — reveal one explicitly when you need it.</p>
      <div class="lab">Name</div>
      <div class="field"><input type="text" class="mono" placeholder="OPENROUTER_API_KEY" bind:value={fName} /></div>
      <div class="lab">Value</div>
      <div class="field">
        <input type="text" class="mono" placeholder={editing ? 'leave blank to keep current value' : 'secret value'} bind:value={fValue} />
      </div>
      <div class="sheet-foot">
        <button class="btn" type="button" onclick={() => (editOpen = false)}>Cancel</button>
        <button class="btn primary" type="button" onclick={save} disabled={saving}>{saving ? 'Saving…' : editing ? 'Save' : 'Add secret'}</button>
      </div>
    </div>
  </div>
{/if}

<Confirm
  open={!!deleteFor}
  title="Delete this secret?"
  body={deleteFor ? `“${deleteFor.name}” will be removed from ${nxName}. Anything relying on it will stop seeing it.` : ''}
  confirmLabel="Delete" danger
  onconfirm={reallyDelete}
  oncancel={() => (deleteFor = null)}
/>

<style>
  .grphead { display:flex; align-items:flex-start; justify-content:space-between; gap:16px; margin:0 0 14px; }
  .grp { font-size:13px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; margin:0; font-weight:700; }
  table.env { width:100%; border-collapse:collapse; font:400 13.5px var(--read); }
  table.env th {
    text-align:left; padding:10px 14px; font:700 11px var(--mono); letter-spacing:.05em;
    text-transform:uppercase; color:var(--dim); border-bottom:1px solid var(--line); background:var(--card);
  }
  table.env td { padding:11px 14px; border-bottom:1px solid var(--line); vertical-align:middle; }
  table.env tr:last-child td { border-bottom:none; }
  .nm { font-weight:600; color:var(--ink); }
  .val { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .masked { letter-spacing:.1em; color:var(--dim); }
  .plain { color:var(--ink); word-break:break-all; }
  .acts { text-align:right; white-space:nowrap; }
  .lk { background:none; border:none; cursor:pointer; padding:2px 4px; font:600 12px var(--read); color:var(--dim); }
  .lk:hover { color:var(--ink); }
  .lk.danger:hover { color:var(--bad, #c0392b); }
  .lk:disabled { opacity:.5; cursor:default; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
</style>
