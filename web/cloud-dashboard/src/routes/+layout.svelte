<script>
  import '../app.css';
  import { page } from '$app/state';
  import NewNexusModal from '$lib/NewNexusModal.svelte';
  import DnaStrip from '$lib/DnaStrip.svelte';
  import Toast from '$lib/Toast.svelte';
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  import { workspaceStore } from '$lib/workspaceStore.svelte.js';
  import EmojiPicker from '$lib/EmojiPicker.svelte';
  import { toast } from '$lib/toastStore.svelte.js';
  import { goto } from '$app/navigation';

  let { children, data } = $props();
  let modalOpen = $state(false);
  let orgOpen = $state(false);

  // Load the org's REAL nexuses + workspaces from the platform API (client-side only —
  // the stores are module singletons, so loading during SSR could bleed one org's data
  // into another request). Empty until a runtime is connected; never fabricated.
  $effect(() => {
    nexusStore.load();
    const defaultWs = data?.profile?.orgName || (data?.user?.email || '').split('@')[0] || 'Workspace';
    workspaceStore.load(defaultWs);
  });

  // ── workspace edit/create (inline in the switcher) ──
  // Uses the same emoji picker as the desktop app ($lib/EmojiPicker → emoji-picker-element).
  let editingId = $state(null); // a workspace id, or 'new', or null
  let editName = $state('');
  let editIcon = $state('');
  let pickerOpen = $state(false);
  const editingWs = $derived(workspaceStore.list.find((w) => w.id === editingId) || null);

  function startEdit(w) { editingId = w.id; editName = w.name; editIcon = w.icon || ''; pickerOpen = false; }
  function startNew() { editingId = 'new'; editName = ''; editIcon = ''; pickerOpen = false; }
  function cancelEdit() { editingId = null; editName = ''; editIcon = ''; pickerOpen = false; }

  async function saveEdit() {
    const n = editName.trim();
    if (!n) return;
    try {
      if (editingId === 'new') {
        const ws = await workspaceStore.create(n, editIcon);
        toast(`Created “${ws.name}”`);
      } else {
        await workspaceStore.update(editingId, { name: n, icon: editIcon });
        toast('Workspace updated');
      }
      cancelEdit();
      orgOpen = false;
    } catch {
      toast('Couldn’t save the workspace', 'bad');
    }
  }

  async function deleteWs() {
    const w = editingWs;
    if (!w) return;
    const ok = await workspaceStore.remove(w.id);
    if (!ok) { toast('Can’t delete your only workspace', 'bad'); return; }
    toast(`Deleted “${w.name}”`);
    cancelEdit();
  }

  // /welcome + /denied render full-bleed, without the app chrome.
  const bare = $derived(page.url.pathname === '/welcome' || page.url.pathname === '/denied');

  // each section gets its own pastel "little touch" (progress bars, accents) via --section
  const sectionAccent = $derived.by(() => {
    const p = page.url.pathname;
    if (p.startsWith('/storage')) return 'var(--sky)';
    if (p.startsWith('/team')) return 'var(--peach)';
    if (p.startsWith('/shared')) return 'var(--cream)';
    if (p.startsWith('/usage')) return 'var(--sage)';
    if (p.startsWith('/settings')) return 'var(--violet)';
    return 'var(--mint)'; // nexuses / home / detail
  });
  // the signed-in user (from the WorkOS session via +layout.server.js)
  const userName = $derived(data?.user ? ([data.user.firstName, data.user.lastName].filter(Boolean).join(' ') || data.user.email.split('@')[0]) : 'Account');
  const userEmail = $derived(data?.user?.email || '');
  const initial = $derived((userName[0] || 'A').toUpperCase());

  // org/workspace identity in the switcher — from onboarding, falling back to the
  // signed-in user (personal accounts) or their email handle.
  const orgLabel = $derived(
    data?.profile?.orgName ||
    (data?.profile?.accountType === 'personal' ? userName : null) ||
    (data?.user?.email ? data.user.email.split('@')[0] : 'workspace')
  );
  const orgInitials = $derived(
    orgLabel.split(/[\s-]+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('') || 'W'
  );

  // the active workspace drives the switcher (org is the parent context shown above it)
  const activeWs = $derived(workspaceStore.active);
  const wsLabel = $derived(activeWs?.name || orgLabel);
  const wsInitials = $derived(
    wsLabel.split(/[\s-]+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('') || 'W'
  );

  // when searching, make sure results are visible on the list page
  function onSearch(e) {
    nexusStore.query = e.currentTarget.value;
    if (nexusStore.query && page.url.pathname !== '/') goto('/');
  }

  // theme — dark default; the inline script in app.html sets data-theme before paint
  let theme = $state('dark');
  if (typeof document !== 'undefined') theme = document.documentElement.getAttribute('data-theme') || 'dark';
  function toggleTheme() {
    theme = theme === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem('wb-theme', theme); } catch {}
  }

  // crumb derived from the current route
  const crumb = $derived.by(() => {
    const p = page.url.pathname;
    if (p === '/' || p.startsWith('/nexuses')) {
      const m = p.match(/^\/nexuses\/(.+)$/);
      return m ? { label: 'Nexuses', tail: m[1] } : { label: 'Nexuses' };
    }
    if (p.startsWith('/team')) return { label: 'Team' };
    if (p.startsWith('/storage')) return { label: 'Storage' };
    if (p.startsWith('/usage')) return { label: 'Usage & billing' };
    if (p.startsWith('/settings')) return { label: 'Settings' };
    return { label: 'Nexuses' };
  });

  function active(...prefixes) {
    const p = page.url.pathname;
    return prefixes.some((pre) => (pre === '/' ? p === '/' : p.startsWith(pre)));
  }
</script>

{#if bare}
  {@render children()}
{:else}
<div id="app" style="--section:{sectionAccent}">
  <!-- sidebar -->
  <aside class="side">
    <div class="topdna"><DnaStrip seed={7} height={8} /></div>
    <div class="brand">
      <svg viewBox="0 0 113.444 65.6002" fill="none"><path fill="currentColor" d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308 65.53 10.08 65.175 19.962 65.462 29.738 65.487 30.568 65.871 31.142 66.391 31.743 72.108 33.464 84.752 13.845 90.921 11.74 93.907 12.344 100.087 19.999 102.273 22.457 98.731 28.417 83.273 40.691 81.382 45.003 81.4 46.287 81.45 46.326 82.157 47.442 83.708 48.637 108.252 47.988 113.133 48.464 113.57 53.985 113.431 59.865 113.391 65.428 101.67 65.449 86.679 66.781 76.472 61.69 68.049 57.527 61.65 50.16 58.704 41.238 57.939 38.586 57.387 36.15 56.78 33.468 55.6 38.7 54.677 42.988 51.921 47.705 39.805 68.442 20.228 65.456 0.065 65.389-0.058 59.646-0.006 53.901 0.222 48.161 5.512 48.136 28.425 48.742 31.699 47.27 31.862 46.897 31.905 46.848 31.987 46.404 32.672 42.681 14.558 27.349 11.618 22.838L11.373 22.456C13.177 19.907 19.347 13.073 22.063 11.774 25.791 11.211 40.002 29.83 44.456 31.689 45.845 32.268 46.068 32.231 47.291 31.751 48.666 29.798 48.206 22.821 48.217 20.153L48.271 0.137Z"/></svg>
      <b>Workbooks</b>
      <button class="themebtn" onclick={toggleTheme} aria-label="Toggle theme" title="Toggle dark / light">
        {#if theme === 'dark'}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
        {:else}
          <svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>
        {/if}
      </button>
    </div>

    {#snippet wsEditor(isNew)}
      <div class="wsedit">
        <div class="wsiconrow">
          <button class="wstile" class:on={pickerOpen} onclick={() => (pickerOpen = !pickerOpen)} title="Change icon" aria-label="Change icon">
            {editIcon || (editName.trim()[0] || 'W').toUpperCase()}
          </button>
          <!-- svelte-ignore a11y_autofocus -->
          <input
            class="wsinput"
            autofocus
            bind:value={editName}
            placeholder="Workspace name"
            onkeydown={(e) => { if (e.key === 'Enter') saveEdit(); if (e.key === 'Escape') cancelEdit(); }}
          />
        </div>
        {#if pickerOpen}
          <div class="wspicker">
            <EmojiPicker onpick={(u) => { editIcon = u; pickerOpen = false; }} />
            <button class="wsinitials" onclick={() => { editIcon = ''; pickerOpen = false; }}>Use initials instead</button>
          </div>
        {/if}
        <div class="wsactions">
          {#if !isNew}<button class="wsdel" onclick={deleteWs}>Delete</button>{/if}
          <span style="flex:1"></span>
          <button class="wscancel" onclick={cancelEdit}>Cancel</button>
          <button class="wssave" onclick={saveEdit}>{isNew ? 'Add' : 'Save'}</button>
        </div>
      </div>
    {/snippet}

    <div class="orgwrap">
      <div class="org" onclick={() => (orgOpen = !orgOpen)} role="button" tabindex="0">
        <div class="av">{activeWs?.icon || wsInitials}</div>
        <div class="nm">
          <div class="wsname">{wsLabel}</div>
          <div class="wsorg">{orgLabel}</div>
        </div>
        <svg class="ico ch" viewBox="0 0 24 24"><path fill="currentColor" d="M7 10l5 5 5-5z"/></svg>
      </div>
      {#if orgOpen}
        <div class="orgmenu" role="menu">
          <div class="omhead">{orgLabel}</div>
          {#each workspaceStore.list as w (w.id)}
            {#if editingId === w.id}
              {@render wsEditor(false)}
            {:else}
              <div class="wsrow" class:on={activeWs?.id === w.id}>
                <button class="wsmain" onclick={() => { workspaceStore.setActive(w.id); orgOpen = false; }}>
                  <span class="av sm">{w.icon || (w.name[0] || 'W').toUpperCase()}</span>
                  <span class="omname">{w.name}</span>
                  {#if activeWs?.id === w.id}<span class="omtick">✓</span>{/if}
                </button>
                <button class="wsedit-btn" onclick={() => startEdit(w)} title="Edit workspace" aria-label="Edit workspace">✎</button>
              </div>
            {/if}
          {/each}
          {#if workspaceStore.list.length === 0}
            <div class="omempty">No workspaces yet</div>
          {/if}
          <div class="omdiv"></div>
          {#if editingId === 'new'}
            {@render wsEditor(true)}
          {:else}
            <button class="omitem" onclick={startNew}>
              <span class="av sm plus">+</span><span class="omname">New workspace</span><small>free</small>
            </button>
          {/if}
          <div class="omdiv"></div>
          <button class="omitem" disabled>Switch organization<small>soon</small></button>
          <a class="omitem" href="/settings" onclick={() => (orgOpen = false)}>Settings</a>
        </div>
      {/if}
    </div>

    <nav class="nav">
      <a href="/" class:on={active('/', '/nexuses')}><svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M4 4h7v7H4V4Zm9 0h7v7h-7V4ZM4 13h7v7H4v-7Zm9 0h7v7h-7v-7Z"/></svg>Nexuses</a>
      <a href="/storage" class:on={active('/storage')}><svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M12 3c4.4 0 8 1.3 8 3v12c0 1.7-3.6 3-8 3s-8-1.3-8-3V6c0-1.7 3.6-3 8-3Zm6 6.6c-1.5.8-3.7 1.4-6 1.4s-4.5-.6-6-1.4V12c0 .6 2.4 2 6 2s6-1.4 6-2V9.6ZM12 5C8.7 5 6 5.8 6 6s2.7 1 6 1 6-.8 6-1-2.7-1-6-1Z"/></svg>Storage</a>
      <span class="lbl">workspace</span>
      <a href="/team" class:on={active('/team')}><svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M16 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-8 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0 2c-2.7 0-8 1.3-8 4v3h10v-3c0-1 .4-1.9 1-2.6-.9-.3-2-.4-3-.4Zm8 0c-.4 0-.8 0-1.3.1C16.1 14 17 15.3 17 17v3h7v-3c0-2.7-5.3-4-8-4Z"/></svg>Team</a>
      <a href="/shared" class:on={active('/shared')}><svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8l-2-2Zm8 12h-2v2h-2v-2h-2v-2h2v-2h2v2h2v2Z"/></svg>Shared folders</a>
      <a href="/usage" class:on={active('/usage')}><svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M4 13h4v7H4v-7Zm6-6h4v13h-4V7Zm6 3h4v10h-4V10Z"/></svg>Usage &amp; billing</a>
      <a href="/settings" class:on={active('/settings')}><svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Zm9 4c0-.6 0-1.2-.1-1.7l2-1.6-2-3.4-2.4 1a7.6 7.6 0 0 0-3-1.7L15 0H9l-.5 2.6a7.6 7.6 0 0 0-3 1.7l-2.4-1-2 3.4 2 1.6c-.1.5-.1 1.1-.1 1.7s0 1.2.1 1.7l-2 1.6 2 3.4 2.4-1c.9.7 1.9 1.3 3 1.7L9 24h6l.5-2.6c1.1-.4 2.1-1 3-1.7l2.4 1 2-3.4-2-1.6c.1-.5.1-1.1.1-1.7Z"/></svg>Settings</a>
    </nav>

    <div class="acct" style="display:flex;align-items:center;gap:4px">
      <a href="/settings" style="display:flex;align-items:center;gap:9px;flex:1;text-decoration:none;color:inherit;min-width:0">
        <div class="av">{initial}</div>
        <div style="flex:1;min-width:0">
          <div class="nm">{userName}</div>
          <div class="em">{userEmail}</div>
        </div>
      </a>
      <a href="/logout" title="Sign out" aria-label="Sign out" style="display:grid;place-items:center;width:30px;height:30px;flex:none;border-radius:8px;color:var(--dim)">
        <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M16 17v-2H9v-2h7V9l5 4-5 4ZM4 5h8V3H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h8v-2H4V5Z"/></svg>
      </a>
    </div>
  </aside>

  <!-- main -->
  <div class="main">
    <div class="topbar">
      <div class="crumb">{crumb.label}{#if crumb.tail}<span> / {crumb.tail}</span>{/if}</div>
      <div class="search">
        <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M10 2a8 8 0 1 0 4.9 14.3l5.4 5.4 1.4-1.4-5.4-5.4A8 8 0 0 0 10 2Zm0 2a6 6 0 1 1 0 12 6 6 0 0 1 0-12Z"/></svg>
        <input placeholder="Search nexuses…" value={nexusStore.query} oninput={onSearch} />
      </div>
      <button class="btn primary" onclick={() => (modalOpen = true)}>
        <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg>
        New nexus
      </button>
    </div>

    <div class="wrap">
      {@render children()}
    </div>
  </div>
</div>

<NewNexusModal open={modalOpen} onclose={() => (modalOpen = false)} />
{/if}
<Toast />

<style>
  .orgwrap { position: relative; }
  .orgmenu {
    position: absolute;
    top: calc(100% + 6px);
    left: 0;
    right: 0;
    z-index: 35;
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 11px;
    padding: 6px;
    animation: org-in 0.12s ease;
  }
  @keyframes org-in {
    from { transform: translateY(-4px); opacity: 0; }
    to { transform: translateY(0); opacity: 1; }
  }
  .omcur {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 9px;
    font: 600 13px var(--read);
    color: var(--ink);
  }
  .omcur .av.sm {
    width: 20px;
    height: 20px;
    border-radius: 6px;
    background: linear-gradient(135deg, var(--mint), var(--sky));
    display: grid;
    place-items: center;
    font: 700 9px var(--read);
    color: var(--ink);
    flex: none;
  }
  .omcur span:nth-child(2) { flex: 1; }
  .omtick { color: var(--run); }
  .omdiv { height: 1px; background: var(--line); margin: 5px 4px; }
  .omitem {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    text-align: left;
    padding: 8px 9px;
    border: none;
    background: none;
    border-radius: 8px;
    color: var(--ink);
    font: 500 13px var(--read);
    cursor: pointer;
    text-decoration: none;
  }
  .omitem:hover { background: var(--line); }
  .omitem[disabled] { color: var(--dim); cursor: default; }
  .omitem[disabled]:hover { background: none; }
  .omitem small { color: var(--dim); font-size: 10px; }

  /* workspace switcher */
  .org .nm { display: flex; flex-direction: column; gap: 1px; flex: 1; min-width: 0; }
  .wsname { font: 600 13px var(--read); color: var(--ink); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .wsorg { font: 500 10.5px var(--read); color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .omhead { font: 700 9.5px var(--read); letter-spacing: 0.06em; text-transform: uppercase; color: var(--dim); padding: 6px 9px 4px; }
  .omitem { gap: 8px; }
  .omname { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .omitem .av.sm {
    width: 20px; height: 20px; border-radius: 6px; flex: none;
    background: linear-gradient(135deg, var(--mint), var(--sky));
    display: grid; place-items: center; font: 700 9px var(--read); color: var(--ink);
  }
  .av.sm.plus { background: var(--line); color: var(--ink); font-size: 13px; }
  .omempty { padding: 8px 9px; font: 500 12px var(--read); color: var(--dim); }

  /* workspace rows: switch (main) + edit (pencil, on hover) */
  .wsrow { display: flex; align-items: center; border-radius: 8px; }
  .wsrow:hover { background: var(--line); }
  .wsrow.on .wsmain { font-weight: 600; }
  .wsmain {
    display: flex; align-items: center; gap: 8px; flex: 1; min-width: 0;
    padding: 8px 9px; border: none; background: none; color: var(--ink);
    font: 500 13px var(--read); cursor: pointer; text-align: left;
  }
  .wsmain .av.sm { font-size: 12px; }
  .wsedit-btn {
    flex: none; width: 26px; height: 26px; margin-right: 5px; border: none; border-radius: 6px;
    background: none; color: var(--dim); cursor: pointer; opacity: 0; font-size: 12px;
  }
  .wsrow:hover .wsedit-btn { opacity: 1; }
  .wsedit-btn:hover { background: var(--card); color: var(--ink); }

  /* inline editor (create + edit) */
  .wsedit { padding: 8px 7px; display: flex; flex-direction: column; gap: 8px; }
  .wsiconrow { display: flex; align-items: center; gap: 7px; }
  .wstile {
    flex: none; width: 34px; height: 34px; display: grid; place-items: center;
    border: 1px solid var(--stroke); border-radius: 9px; background: var(--card);
    color: var(--ink); cursor: pointer; font: 600 14px var(--read);
  }
  .wstile:hover, .wstile.on { border-color: var(--ink); }
  .wspicker { display: flex; flex-direction: column; gap: 5px; }
  .wsinitials {
    align-self: flex-start; border: none; background: none; color: var(--dim);
    font: 500 11.5px var(--read); cursor: pointer; padding: 2px 0;
  }
  .wsinitials:hover { color: var(--ink); }
  .wsinput {
    flex: 1; min-width: 0; font: 500 13px var(--read); padding: 8px 10px;
    border: 1px solid var(--stroke); border-radius: 8px; background: var(--card); color: var(--ink); outline: none;
  }
  .wsinput:focus { border-color: var(--ink); }
  .wsactions { display: flex; align-items: center; gap: 6px; }
  .wsactions button { border: none; border-radius: 7px; padding: 6px 11px; font: 600 12px var(--read); cursor: pointer; }
  .wsdel { background: none; color: var(--bad, #d4604a); }
  .wsdel:hover { background: color-mix(in srgb, var(--bad, #d4604a) 14%, transparent); }
  .wscancel { background: var(--line); color: var(--ink); }
  .wssave { background: var(--ink); color: var(--paper); }
</style>
