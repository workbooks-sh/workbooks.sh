<script>
  import { onMount } from 'svelte';
  import { envStore } from '$lib/envStore.svelte.js';
  import { workspaceStore } from '$lib/workspaceStore.svelte.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';

  // Per-workspace env vars / secrets (Doppler-like). The active workspace scopes
  // everything — the sidebar switcher is the selector, so this page re-loads when
  // workspaceStore.active changes. The list is REDACTED (masked + length); plaintext
  // crosses ONLY on an explicit per-row Reveal, shown transiently and never persisted.
  const wsName = $derived(workspaceStore.active?.name || 'this workspace');

  // Re-load on workspace switch. $effect tracks workspaceStore.active.id.
  $effect(() => {
    const id = workspaceStore.active?.id;
    if (id) envStore.load(id);
  });
  onMount(() => {
    const id = workspaceStore.active?.id;
    if (id) envStore.load(id);
  });

  // Revealed plaintext — local, transient, keyed by var id. NEVER written to the store.
  let revealed = $state({}); // { [id]: string }
  let revealBusy = $state(null);
  const timers = {};

  async function reveal(id) {
    if (revealed[id] !== undefined) return hide(id);
    revealBusy = id;
    try {
      const value = await envStore.reveal(id);
      revealed = { ...revealed, [id]: value };
      // auto-hide after 30s
      clearTimeout(timers[id]);
      timers[id] = setTimeout(() => hide(id), 30000);
    } catch {
      toast('Could not reveal this value', 'bad');
    }
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
    try {
      await navigator.clipboard.writeText(v);
      toast('Copied to clipboard');
    } catch {
      toast('Could not copy', 'bad');
    }
  }

  // Create / edit modal
  let editOpen = $state(false);
  let editing = $state(null); // null = create, else the row being edited
  let fName = $state('');
  let fValue = $state('');
  let saving = $state(false);

  function openCreate() {
    editing = null;
    fName = '';
    fValue = '';
    editOpen = true;
  }
  function openEdit(v) {
    editing = v;
    fName = v.name;
    fValue = ''; // never pre-load plaintext — blank means "keep existing"
    editOpen = true;
  }
  async function save() {
    if (!fName.trim()) { toast('Give the variable a name'); return; }
    saving = true;
    try {
      if (editing) {
        const attrs = { name: fName.trim() };
        if (fValue) attrs.value = fValue; // blank ⇒ keep existing secret
        await envStore.update(editing.id, attrs);
        toast(`Updated ${fName.trim()}`);
      } else {
        if (!fValue) { saving = false; toast('Give the variable a value'); return; }
        await envStore.create(fName.trim(), fValue);
        toast(`Added ${fName.trim()}`);
      }
      editOpen = false;
    } catch {
      toast('Could not save', 'bad');
    }
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
  <h3 class="grp">Env vars · {wsName}</h3>
  <button class="btn sm primary" onclick={openCreate}>
    <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Add variable
  </button>
</div>

{#if envStore.loading}
  <div class="card" style="color:var(--dim);text-align:center">Loading…</div>
{:else if envStore.list.length === 0}
  <div class="card faint" style="text-align:center">
    No variables yet. Secrets you add here are encrypted and available to {wsName}.
  </div>
{:else}
  <div class="card" style="padding:0;overflow:hidden">
    <table class="env">
      <thead>
        <tr><th>Name</th><th>Value</th><th>Created</th><th></th></tr>
      </thead>
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
      <h2>{editing ? 'Edit variable' : 'Add variable'}</h2>
      <p class="sub">Secrets are encrypted at rest. The value is shown masked everywhere — reveal one explicitly when you need it.</p>

      <div class="lab">Name</div>
      <div class="field"><input type="text" class="mono" placeholder="DATABASE_URL" bind:value={fName} /></div>

      <div class="lab">Value</div>
      <div class="field">
        <input type="text" class="mono" placeholder={editing ? 'leave blank to keep current value' : 'secret value'} bind:value={fValue} />
      </div>

      <div class="sheet-foot">
        <button class="btn" type="button" onclick={() => (editOpen = false)}>Cancel</button>
        <button class="btn primary" type="button" onclick={save} disabled={saving}>{saving ? 'Saving…' : editing ? 'Save' : 'Add variable'}</button>
      </div>
    </div>
  </div>
{/if}

<Confirm
  open={!!deleteFor}
  title="Delete this variable?"
  body={deleteFor ? `“${deleteFor.name}” will be removed from ${wsName}. Anything relying on it will stop seeing it.` : ''}
  confirmLabel="Delete"
  danger
  onconfirm={reallyDelete}
  oncancel={() => (deleteFor = null)}
/>

<style>
  .grphead { display:flex; align-items:center; justify-content:space-between; margin:0 0 10px; }
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
  .lk {
    background:none; border:none; cursor:pointer; padding:2px 4px;
    font:600 12px var(--read); color:var(--dim);
  }
  .lk:hover { color:var(--ink); }
  .lk.danger:hover { color:var(--bad, #c0392b); }
  .lk:disabled { opacity:.5; cursor:default; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
</style>
