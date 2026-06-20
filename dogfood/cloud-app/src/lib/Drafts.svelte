<script>
  import { listDrafts, createDraft, draftDiff, keepDraft, discardDraft } from '$lib/api.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';

  // The Drafts panel: "try a change safely — Keep it or Discard it." The live
  // version keeps serving while a Draft is edited. Zero git words — only Draft /
  // preview / Keep / Discard. `nexus` = the workspace id.
  let { nexus } = $props();

  let drafts = $state([]);
  let loading = $state(true);
  let openName = $state(null);
  let changes = $state(null);
  let busy = $state(null);
  let newOpen = $state(false);
  let newName = $state('');
  let discardFor = $state(null);

  async function load() {
    loading = true;
    drafts = await listDrafts(nexus);
    loading = false;
  }
  $effect(() => { nexus; load(); });

  async function toggle(d) {
    if (openName === d.name) { openName = null; changes = null; return; }
    openName = d.name; changes = null;
    changes = await draftDiff(nexus, d.name);
  }

  async function startDraft() {
    const name = newName.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
    if (!name) { toast('Give the draft a name'); return; }
    const d = await createDraft(nexus, name);
    drafts = [d, ...drafts];
    newOpen = false; newName = '';
    toast(`Draft “${d.name}” started`);
  }

  async function keep(d) {
    busy = d.name;
    await keepDraft(nexus, d.name);
    busy = null;
    drafts = drafts.filter((x) => x.name !== d.name);
    openName = null; changes = null;
    toast(`Kept “${d.name}” — it’s now live`);
  }

  async function reallyDiscard() {
    const d = discardFor;
    discardFor = null;
    busy = d.name;
    await discardDraft(nexus, d.name);
    busy = null;
    drafts = drafts.filter((x) => x.name !== d.name);
    openName = null; changes = null;
    toast(`Discarded “${d.name}”`, 'bad');
  }

  const STATUS_STYLE = {
    added: 'color:var(--bloomd)',
    modified: 'color:var(--amber)',
    removed: 'color:var(--bad)'
  };
  const statusMark = { added: '+ new', modified: '~ changed', removed: '− removed' };
</script>

<div class="card" style="padding:0;overflow:hidden">
  <div class="dh">
    <div style="display:flex;flex-direction:column;gap:1px">
      <b style="font-size:13.5px">Drafts <span class="dim mono" style="font-weight:400">· {drafts.length}</span></b>
      <span class="faint" style="font-size:11.5px">Try a change safely — the live version keeps running until you Keep.</span>
    </div>
    <button class="btn sm primary" onclick={() => (newOpen = true)}>
      <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> New draft
    </button>
  </div>

  {#if loading}
    <div class="empty">Loading…</div>
  {:else if drafts.length === 0}
    <div class="empty">No drafts. Start one to try changes without touching the live version.</div>
  {:else}
    <ul class="dl">
      {#each drafts as d (d.name)}
        <li>
          <button class="row" onclick={() => toggle(d)} aria-expanded={openName === d.name}>
            <span class="dot draft"></span>
            <span class="meta">
              <span class="dname">{d.name}</span>
              <span class="sub">{d.files_changed} {d.files_changed === 1 ? 'change' : 'changes'}</span>
            </span>
            <span class="caret" class:up={openName === d.name}>›</span>
          </button>

          {#if openName === d.name}
            <div class="body">
              {#if changes === null}
                <div class="empty" style="border:0;padding:14px">Loading changes…</div>
              {:else if changes.length === 0}
                <div class="faint" style="padding:6px 0 12px;font-size:12.5px">No changes yet in this draft.</div>
              {:else}
                <ul class="files">
                  {#each changes as c}
                    <li><span class="mono" style="font-size:12.5px">{c.path}</span><span class="mono" style="font-size:11px;{STATUS_STYLE[c.status]}">{statusMark[c.status]}</span></li>
                  {/each}
                </ul>
              {/if}
              <div class="acts">
                <a class="btn sm" href={'/' + d.preview_path} onclick={(e) => { e.preventDefault(); toast('Opening preview…'); }}>Preview</a>
                <div style="flex:1"></div>
                <button class="btn sm" onclick={() => (discardFor = d)} disabled={busy === d.name}>Discard</button>
                <button class="btn sm primary" onclick={() => keep(d)} disabled={busy === d.name}>{busy === d.name ? 'Keeping…' : 'Keep'}</button>
              </div>
            </div>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>

{#if newOpen}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) newOpen = false; }}>
    <div class="sheet" style="width:420px">
      <h2>New draft</h2>
      <p class="sub">A draft is a safe copy of this workspace. Edits stay in the draft until you Keep them.</p>
      <div class="lab">Name</div>
      <div class="field"><input type="text" placeholder="spring-refresh" bind:value={newName} onkeydown={(e) => { if (e.key === 'Enter') startDraft(); }} /></div>
      <div class="sheet-foot">
        <button class="btn" type="button" onclick={() => (newOpen = false)}>Cancel</button>
        <button class="btn primary" type="button" onclick={startDraft}>Start draft</button>
      </div>
    </div>
  </div>
{/if}

<Confirm
  open={!!discardFor}
  title="Discard this draft?"
  body={discardFor ? `“${discardFor.name}” and its ${discardFor.files_changed} change${discardFor.files_changed === 1 ? '' : 's'} will be thrown away. The live version is untouched.` : ''}
  confirmLabel="Discard draft"
  danger
  onconfirm={reallyDiscard}
  oncancel={() => (discardFor = null)}
/>

<style>
  .dh { display:flex; align-items:center; justify-content:space-between; gap:12px;
    padding:14px 18px; border-bottom:2px solid var(--line); }
  .empty { padding:24px 18px; text-align:center; color:var(--dim); font-size:13px; }
  .dl { list-style:none; margin:0; padding:6px 0; }
  .dl > li { border-bottom:1px solid var(--line); }
  .dl > li:last-child { border-bottom:0; }
  .row { width:100%; display:flex; align-items:center; gap:11px; padding:12px 18px;
    background:none; border:0; cursor:pointer; text-align:left; color:inherit; }
  .row:hover { background:color-mix(in srgb, var(--ink) 4%, transparent); }
  .dot.draft { width:9px; height:9px; border-radius:50%; flex:none; background:var(--amber);
    box-shadow:0 0 0 3px color-mix(in srgb, var(--amber) 22%, transparent); }
  .meta { flex:1; min-width:0; display:flex; flex-direction:column; gap:1px; }
  .dname { font-weight:600; font-size:13.5px; }
  .sub { font-size:11.5px; color:var(--dim); }
  .caret { font-size:18px; color:var(--dim); transition:transform .15s; }
  .caret.up { transform:rotate(90deg); }
  .body { padding:2px 18px 16px 38px; }
  .files { list-style:none; margin:0 0 12px; padding:0; }
  .files li { display:flex; justify-content:space-between; padding:4px 0; border-bottom:1px solid var(--line); }
  .files li:last-child { border-bottom:0; }
  .acts { display:flex; align-items:center; gap:8px; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
</style>
