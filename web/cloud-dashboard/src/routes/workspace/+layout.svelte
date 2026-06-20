<script>
  // Workspace admin surface — the GOVERNANCE plane for the active workspace.
  // Reached from the Workspace switcher's "Workspace settings" link. Three tabs:
  // Members & access · Sharing · History. The active workspace scopes everything;
  // its name is read straight from the workspace switcher store.
  import { page } from '$app/state';
  import { workspaceStore } from '$lib/workspaceStore.svelte.js';

  let { children } = $props();

  const ws = $derived(workspaceStore.active);
  const wsName = $derived(ws?.name || 'Workspace');
  const wsIcon = $derived(ws?.icon || (wsName[0] || 'W').toUpperCase());

  const TABS = [
    { href: '/workspace', label: 'Structure' },
    { href: '/workspace/members', label: 'Members & access' },
    { href: '/workspace/sharing', label: 'Sharing' },
    { href: '/workspace/history', label: 'History' },
    { href: '/workspace/env', label: 'Secrets' }
  ];
  const here = $derived(page.url.pathname);
  // '/workspace' is the Structure index — exact match so it isn't "on" for every sub-tab.
  const isOn = (href) => href === '/workspace' ? here === '/workspace' : (here === href || here.startsWith(href + '/'));
</script>

<section>
  <div class="wshead">
    <span class="wsav">{wsIcon}</span>
    <div>
      <h2>{wsName}</h2>
      <p>Workspace governance — who's in it, what's shared, and everything that's changed.</p>
    </div>
  </div>

  <nav class="wstabs">
    {#each TABS as t (t.href)}
      <a href={t.href} class:on={isOn(t.href)}>{t.label}</a>
    {/each}
  </nav>

  {@render children()}
</section>

<style>
  .wshead { display:flex; align-items:center; gap:14px; margin-bottom:18px; }
  .wsav {
    width:40px; height:40px; border-radius:11px; flex:none; display:grid; place-items:center;
    background:var(--line); color:var(--ink);
    font:700 16px var(--read);
  }
  .wshead h2 { font-family:var(--display); font-weight:600; font-size:24px; line-height:1.1; color:var(--ink); }
  .wshead p { font:400 13.5px var(--read); color:var(--prose); margin-top:3px; }

  .wstabs {
    display:flex; gap:2px; margin-bottom:22px;
    border-bottom:1px solid var(--line);
  }
  .wstabs a {
    padding:9px 14px; font:600 13px var(--read); color:var(--dim);
    text-decoration:none; border-bottom:2px solid transparent; margin-bottom:-1px;
    transition:color .1s;
  }
  .wstabs a:hover { color:var(--ink); }
  .wstabs a.on { color:var(--ink); border-bottom-color:var(--section); }
</style>
