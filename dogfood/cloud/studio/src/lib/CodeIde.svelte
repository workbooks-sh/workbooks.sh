<script>
  // The Code workbench — FULLY CUSTOM Svelte, no VS Code / monaco-vscode-api. It composes our own primitives:
  // the FileTree (chrome off) + the CodeMirror FileEditor, wrapped in our own chrome — a FLOATING workbench
  // toolbar at the top (hamburger menu + actions) and a bottom panel (custom WorkTerminal) with a status
  // strip — all in our theme tokens. The "capabilities" (terminal/run/weave) are the seam to washy; here they
  // answer locally so the surface is real today. This replaces the embedded workbench entirely.
  import FileTree from './FileTree.svelte'
  import FileEditor from './FileEditor.svelte'
  import WorkTerminal from './WorkTerminal.svelte'
  import Extensions from './Extensions.svelte'
  import { iconSvgByName } from './icons.js'
  import { fsUi } from './fs.svelte.js'

  let treeOpen = $state(true)
  let leftView = $state('files') // 'files' | 'ext' — what the left column shows
  let panelOpen = $state(false)
  let menuOpen = $state(false)

  const active = () => fsUi.active
  // toggle a left view: same button closes the sidebar if its view is already showing
  function showLeft(view) { if (treeOpen && leftView === view) treeOpen = false; else { leftView = view; treeOpen = true } }

  const menu = [
    { label: 'Explorer', icon: 'multiple-pages', run: () => showLeft('files') },
    { label: 'Extensions', icon: 'puzzle', run: () => showLeft('ext') },
    { label: 'Toggle Terminal', icon: 'terminal', run: () => (panelOpen = !panelOpen) },
    { sep: true },
    { label: 'Weave workspace', icon: 'sparks', run: () => (panelOpen = true) }
  ]
  function pick(m) { menuOpen = false; m.run?.() }
</script>

<svelte:window onclick={() => (menuOpen = false)} />

<div class="h-full w-full flex flex-col min-w-0 min-h-0" style="background:var(--color-paper)">
  <!-- ── floating workbench toolbar ─────────────────────────────────────────────────────────────── -->
  <div class="flex-none px-2 pt-2">
    <div class="flex items-center gap-1.5 h-[40px] px-2 rounded-xl border border-line"
      style="background:var(--color-card); box-shadow:0 2px 10px color-mix(in srgb,var(--color-ink) 7%,transparent)">

      <!-- hamburger menu -->
      <div class="relative">
        <button onclick={(e) => { e.stopPropagation(); menuOpen = !menuOpen }} title="Menu"
          class="w-[30px] h-[30px] grid place-items-center rounded-lg text-ink hoverwash [&>svg]:w-[17px] [&>svg]:h-[17px]">{@html iconSvgByName('menu', 17)}</button>
        {#if menuOpen}
          <div onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1"
            class="absolute left-0 top-[36px] z-[60] min-w-[200px] rounded-xl border border-line py-1.5"
            style="background:var(--color-card); box-shadow:0 18px 40px rgba(0,0,0,.32)">
            {#each menu as m}
              {#if m.sep}<div class="my-1 mx-3 border-t border-line"></div>
              {:else}
                <button onclick={() => pick(m)} role="menuitem"
                  class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13px] hoverwash [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]">
                  <span class="grid place-items-center text-dim">{@html iconSvgByName(m.icon, 15)}</span>{m.label}
                </button>
              {/if}
            {/each}
          </div>
        {/if}
      </div>

      <div class="w-px h-5 bg-line"></div>

      <button onclick={() => showLeft('files')} title="Explorer"
        class="w-[30px] h-[30px] grid place-items-center rounded-lg hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px] {treeOpen && leftView === 'files' ? 'text-ink' : 'text-dim'}">{@html iconSvgByName('multiple-pages', 16)}</button>
      <button onclick={() => showLeft('ext')} title="Extensions (Open VSX)"
        class="w-[30px] h-[30px] grid place-items-center rounded-lg hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px] {treeOpen && leftView === 'ext' ? 'text-ink' : 'text-dim'}">{@html iconSvgByName('puzzle', 16)}</button>

      <!-- breadcrumb / title -->
      <div class="flex items-center gap-2 px-2 min-w-0 flex-1">
        <span class="grid place-items-center text-bloomd [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('sparks', 15)}</span>
        <span class="text-[13px] text-ink font-medium truncate">
          {active() ? active().path.replace(/^\//, '').split('/').join('  ›  ') : 'dogfood'}
        </span>
      </div>

      <!-- action cluster -->
      <button title="Run" class="w-[30px] h-[30px] grid place-items-center rounded-lg text-bloomd hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName('play', 16)}</button>
      <button title="Source control" class="w-[30px] h-[30px] grid place-items-center rounded-lg text-dim hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName('git-fork', 16)}</button>
      <button onclick={() => (panelOpen = !panelOpen)} title="Toggle terminal"
        class="w-[30px] h-[30px] grid place-items-center rounded-lg hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px] {panelOpen ? 'text-ink' : 'text-dim'}">{@html iconSvgByName('terminal', 16)}</button>
    </div>
  </div>

  <!-- ── body: tree + editor ────────────────────────────────────────────────────────────────────── -->
  <div class="flex-1 min-h-0 flex p-2 gap-2">
    {#if treeOpen}
      <div class="w-[236px] flex-none rounded-xl border border-line overflow-hidden" style="background:var(--color-paper)">
        {#if leftView === 'ext'}<Extensions />{:else}<FileTree showHeader={false} />{/if}
      </div>
    {/if}
    <div class="flex-1 min-w-0 flex flex-col gap-2">
      <div class="flex-1 min-h-0 rounded-xl border border-line overflow-hidden" style="background:var(--color-well)">
        <FileEditor />
      </div>
      <!-- ── bottom panel (custom terminal) ── -->
      {#if panelOpen}
        <div class="h-[230px] flex-none rounded-xl border border-line overflow-hidden">
          <WorkTerminal onClose={() => (panelOpen = false)} />
        </div>
      {/if}
    </div>
  </div>

  <!-- ── status strip ───────────────────────────────────────────────────────────────────────────── -->
  <div class="flex-none h-[24px] flex items-center gap-3 px-3 text-[11px] font-mono text-dim border-t border-line" style="background:var(--color-paper)">
    <span class="flex items-center gap-1 [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('git-branch', 12)} wb-d8ac-spine</span>
    <button onclick={() => (panelOpen = !panelOpen)} class="flex items-center gap-1 hover:text-ink [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('terminal', 12)} washy</button>
    <span class="flex-1"></span>
    {#if active()}
      <span>{active().name.split('.').pop()?.toUpperCase()}</span>
      <span>{active().dirty ? '● unsaved' : 'saved'}</span>
    {/if}
    <span class="text-bloomd">● sandbox</span>
  </div>
</div>
