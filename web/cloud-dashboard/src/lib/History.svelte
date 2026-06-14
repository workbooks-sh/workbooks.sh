<script>
  import { nexusHistory, changeDiff, restoreVersion } from '$lib/api.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';

  // The History panel: "nothing is lost — restore anything." Reads the three
  // history endpoints (mock today). Zero git words — only Change / before·after /
  // Restore. `scope` = the nexus (later, a workbook) id.
  let { scope } = $props();

  let changes = $state([]);
  let loading = $state(true);
  let openId = $state(null);            // which change's before/after is expanded
  let diff = $state(null);              // { before, after } for openId
  let diffLoading = $state(false);
  let confirmFor = $state(null);        // the change pending a Restore confirm
  let restoring = $state(false);

  async function load() {
    loading = true;
    changes = await nexusHistory(scope);
    loading = false;
  }
  // re-load whenever the scope changes
  $effect(() => { scope; load(); });

  async function toggle(c) {
    if (openId === c.id) { openId = null; diff = null; return; }
    openId = c.id; diff = null; diffLoading = true;
    diff = await changeDiff(scope, c.id);
    diffLoading = false;
  }

  async function reallyRestore() {
    const c = confirmFor;
    confirmFor = null;
    restoring = true;
    const when = new Date().toISOString();   // caller-stamped (shared api.js stays Date-free)
    const entry = await restoreVersion(scope, c.id, when);
    changes = [entry, ...changes];           // append-only: the restore is a NEW change on top
    openId = null; diff = null;
    restoring = false;
    toast(entry.title);
  }

  // Simple line-level before→after. New lines tint green, dropped lines tint red.
  function lineDiff(before, after) {
    const a = (before || '').split('\n');
    const b = (after || '').split('\n');
    const aset = new Set(a), bset = new Set(b);
    const rows = [];
    for (const ln of a) if (!bset.has(ln)) rows.push({ k: 'del', ln });
    for (const ln of b) rows.push({ k: aset.has(ln) ? 'same' : 'add', ln });
    return rows;
  }

  function who(c) {
    if (c.authorName === 'You') return 'You';
    return c.authorType === 'agent' ? `${c.authorName} · agent` : c.authorName;
  }
  function ago(iso) {
    const d = (Date.now() - new Date(iso)) / 1000;
    if (d < 60) return 'just now';
    if (d < 3600) return Math.floor(d / 60) + 'm ago';
    if (d < 86400) return Math.floor(d / 3600) + 'h ago';
    if (d < 86400 * 7) return Math.floor(d / 86400) + 'd ago';
    return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }
  const initials = (n) => n === 'You' ? 'Y' : n.split(/\s+/).map((p) => p[0]).slice(0, 2).join('').toUpperCase();
</script>

<div class="card" style="padding:0;overflow:hidden">
  <div class="hh">
    <b style="font-size:13.5px">History <span class="dim mono" style="font-weight:400">· {changes.length} change{changes.length === 1 ? '' : 's'}</span></b>
    <span class="faint" style="font-size:11.5px">Nothing is lost — restore any version.</span>
  </div>

  {#if loading}
    <div class="empty">Loading…</div>
  {:else if changes.length === 0}
    <div class="empty">No changes yet. Edits will show up here.</div>
  {:else}
    <ol class="tl">
      {#each changes as c, i (c.id)}
        <li class:open={openId === c.id}>
          <span class="rail"><span class="node {c.authorType}" class:head={i === 0}></span></span>
          <div class="body">
            <button class="row" onclick={() => toggle(c)} aria-expanded={openId === c.id}>
              <span class="av {c.authorType}">{initials(c.authorName)}</span>
              <span class="meta">
                <span class="title">{c.title}</span>
                <span class="sub"><b>{who(c)}</b> · {ago(c.when)}</span>
              </span>
              <span class="caret" class:up={openId === c.id}>›</span>
            </button>

            {#if openId === c.id}
              <div class="diff">
                {#if diffLoading}
                  <div class="empty" style="border:0">Loading before → after…</div>
                {:else if diff}
                  <div class="dgrid">
                    {#each lineDiff(diff.before, diff.after) as r}
                      <div class="dl {r.k}"><span class="sign">{r.k === 'add' ? '+' : r.k === 'del' ? '−' : ' '}</span>{r.ln || ' '}</div>
                    {/each}
                  </div>
                  {#if i !== 0}
                    <div class="dfoot">
                      <button class="btn sm" onclick={() => (confirmFor = c)} disabled={restoring}>
                        ⟲ Restore this version
                      </button>
                    </div>
                  {/if}
                {/if}
              </div>
            {/if}
          </div>
        </li>
      {/each}
    </ol>
  {/if}
</div>

<Confirm
  open={!!confirmFor}
  title="Restore this version?"
  body={confirmFor ? `“${confirmFor.title}” will become the current version. Nothing is deleted — this is added as a new change you can undo.` : ''}
  confirmLabel="Restore"
  onconfirm={reallyRestore}
  oncancel={() => (confirmFor = null)}
/>

<style>
  .hh { display:flex; align-items:center; justify-content:space-between; gap:12px;
    padding:14px 18px; border-bottom:2px solid var(--line); }
  .empty { padding:26px 18px; text-align:center; color:var(--dim); font-size:13px; }

  .tl { list-style:none; margin:0; padding:6px 0; }
  .tl li { display:flex; gap:0; }
  .rail { position:relative; width:34px; flex:none; }
  /* the connecting line */
  .rail::before { content:''; position:absolute; left:50%; top:0; bottom:0; width:2px;
    background:var(--line); transform:translateX(-50%); }
  .tl li:first-child .rail::before { top:18px; }
  .tl li:last-child .rail::before { bottom:auto; height:18px; }
  .node { position:absolute; left:50%; top:16px; width:11px; height:11px; border-radius:50%;
    transform:translateX(-50%); border:2px solid var(--card); box-sizing:content-box; z-index:1;
    background:var(--sky); }
  .node.agent { background:var(--bloomd); }
  .node.head { box-shadow:0 0 0 3px color-mix(in srgb, var(--bloomd) 22%, transparent); }

  .body { flex:1; min-width:0; border-bottom:1px solid var(--line); }
  .tl li:last-child .body { border-bottom:0; }

  .row { width:100%; display:flex; align-items:center; gap:11px; padding:11px 18px 11px 4px;
    background:none; border:0; cursor:pointer; text-align:left; color:inherit; }
  .row:hover { background:var(--panel-2, color-mix(in srgb, var(--ink) 4%, transparent)); }
  .av { width:28px; height:28px; border-radius:50%; flex:none; display:grid; place-items:center;
    font:700 10.5px var(--mono); color:var(--on-bloom); border:2px solid var(--stroke);
    background:var(--sky); }
  .av.agent { background:var(--bloomd); }
  .meta { flex:1; min-width:0; display:flex; flex-direction:column; gap:1px; }
  .title { font-weight:600; font-size:13.5px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .sub { font-size:11.5px; color:var(--dim); }
  .caret { font-size:18px; color:var(--dim); transition:transform .15s; flex:none; padding-right:6px; }
  .caret.up { transform:rotate(90deg); }

  .diff { padding:0 18px 14px 4px; }
  .dgrid { font:12px/1.65 var(--mono); border:2px solid var(--line); border-radius:8px;
    overflow:hidden; background:var(--paper); }
  .dl { padding:0 10px; white-space:pre-wrap; word-break:break-word; }
  .dl .sign { display:inline-block; width:1.1em; color:var(--dim); user-select:none; }
  .dl.add { background:color-mix(in srgb, var(--bloomd) 15%, transparent); }
  .dl.add .sign { color:var(--bloomd); }
  .dl.del { background:var(--bad-fill); }
  .dl.del .sign { color:var(--bad); }
  .dl.del { color:var(--dim); }
  .dfoot { margin-top:10px; }
</style>
