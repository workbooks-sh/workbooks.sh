<script>
  // The Files section = a small IDE: a file-tree (left) + a CodeMirror editor (right) with real
  // syntax highlighting per language and the colorful vscode-icons file glyphs. `.work` gets a
  // branded green glyph so workbook files read as a first-class language in the tree.
  import { fileTree, firstFile } from './fs.svelte.js'
  import { vsIcon, fileIconName, isWorkFile, iconSvgByName } from './icons.js'
  import { EditorView, basicSetup } from 'codemirror'
  import { EditorState, Compartment } from '@codemirror/state'
  import { javascript } from '@codemirror/lang-javascript'
  import { rust } from '@codemirror/lang-rust'
  import { json } from '@codemirror/lang-json'
  import { markdown } from '@codemirror/lang-markdown'
  import { html } from '@codemirror/lang-html'
  import { css } from '@codemirror/lang-css'
  import { elixir } from 'codemirror-lang-elixir'
  import { oneDark } from '@codemirror/theme-one-dark'

  let active = $state(firstFile())
  let tabs = $state(active ? [active] : [])

  function open(node) {
    active = node
    if (!tabs.includes(node)) tabs.push(node)
  }
  function closeTab(node, e) {
    e.stopPropagation()
    const i = tabs.indexOf(node)
    tabs.splice(i, 1)
    if (active === node) active = tabs[Math.min(i, tabs.length - 1)] || null
  }

  // ── editor language by extension ──────────────────────────────────────────────────────────────
  function langFor(name = '') {
    const ext = name.toLowerCase().split('.').pop()
    switch (ext) {
      case 'work': return elixir()  // .work IS literate Elixir-AST → Elixir highlighting
      case 'ex': case 'exs': return elixir()
      case 'js': case 'mjs': case 'cjs': return javascript()
      case 'jsx': return javascript({ jsx: true })
      case 'ts': return javascript({ typescript: true })
      case 'tsx': return javascript({ jsx: true, typescript: true })
      case 'svelte': case 'html': case 'svg': return html()
      case 'rs': return rust()
      case 'json': return json()
      case 'md': return markdown()
      case 'css': return css()
      default: return [] // plain text, still themed
    }
  }

  // ── CodeMirror lifecycle ──────────────────────────────────────────────────────────────────────
  let host
  let view
  $effect(() => {
    const v = new EditorView({ parent: host })
    view = v
    return () => { v.destroy(); view = undefined }
  })
  $effect(() => {
    const a = active
    if (!view) return
    view.setState(EditorState.create({
      doc: a?.content ?? '',
      extensions: [basicSetup, langFor(a?.name), oneDark]
    }))
  })
</script>

<section class="flex h-full min-w-0 bg-paper">
  <!-- file tree -->
  <div class="w-[260px] flex-none border-r border-line flex flex-col">
    <div class="flex items-center gap-2 px-3.5 h-[46px] flex-none mt-2.5 border-b border-line">
      <span class="font-display font-semibold text-[15px] tracking-tight flex-1">Files</span>
      <button class="w-[28px] h-[28px] rounded-lg grid place-items-center text-dim hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]" title="New file">{@html iconSvgByName('plus', 15)}</button>
    </div>
    <div class="flex-1 overflow-y-auto py-1.5 text-[13px]">
      {#each fileTree as node}{@render row(node, 0)}{/each}
    </div>
  </div>

  <!-- editor -->
  <div class="flex-1 min-w-0 flex flex-col" style="background:#282c34">
    <!-- tab bar -->
    <div class="flex items-stretch h-[46px] flex-none border-b border-[#1c2027] overflow-x-auto" style="background:#21252b">
      {#each tabs as t}
        <button onclick={() => (active = t)}
          class="group/tab flex items-center gap-2 px-3.5 border-r border-[#1c2027] text-[12.5px] whitespace-nowrap
            {active === t ? 'text-[#e6e6e6]' : 'text-[#8a919c] hover:text-[#cfd3da]'}"
          style={active === t ? 'background:#282c34;box-shadow:inset 0 2px 0 var(--color-sky)' : ''}>
          <span class="grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]">
            {#if isWorkFile(t.name)}{@html iconSvgByName('journal-page', 15)}{:else}{@html vsIcon(fileIconName(t.name), 15)}{/if}
          </span>
          {t.name}
          <span class="grid place-items-center rounded opacity-0 group-hover/tab:opacity-100 hover:bg-white/10 [&>svg]:w-[13px] [&>svg]:h-[13px]"
            role="button" tabindex="-1" onclick={(e) => closeTab(t, e)}>{@html iconSvgByName('xmark', 13)}</span>
        </button>
      {/each}
    </div>

    {#if active}
      <!-- breadcrumb -->
      <div class="flex items-center gap-1.5 px-4 h-[30px] flex-none text-[11.5px] text-[#6b7280] font-mono" style="background:#282c34">
        {active.path.replace(/^\//, '').split('/').join('  ›  ')}
      </div>
      <div bind:this={host} class="flex-1 min-h-0 overflow-hidden text-[13px]"></div>
    {:else}
      <div class="flex-1 grid place-items-center text-[#6b7280] text-[13px]">No file open</div>
    {/if}
  </div>
</section>

<!-- recursive tree row -->
{#snippet row(node, depth)}
  {#if node.type === 'folder'}
    <button onclick={() => (node.open = !node.open)}
      class="flex items-center gap-1.5 w-full text-left py-[3px] pr-2 hoverwash text-ink/90"
      style="padding-left:{depth * 14 + 8}px">
      <span class="grid place-items-center text-dim transition-transform duration-100 [&>svg]:w-[11px] [&>svg]:h-[11px]" style="transform:rotate({node.open ? 90 : 0}deg)">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </span>
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html vsIcon(node.open ? 'default-folder-opened' : 'default-folder', 16)}</span>
      <span class="truncate">{node.name}</span>
    </button>
    {#if node.open}
      {#each node.children as child}{@render row(child, depth + 1)}{/each}
    {/if}
  {:else}
    <button onclick={() => open(node)}
      class="flex items-center gap-1.5 w-full text-left py-[3px] pr-2 hoverwash {active === node ? '!bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] text-ink' : 'text-ink/80'}"
      style="padding-left:{depth * 14 + 22}px">
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" style={isWorkFile(node.name) ? 'color:var(--color-bloomd)' : ''}>
        {#if isWorkFile(node.name)}{@html iconSvgByName('journal-page', 16)}{:else}{@html vsIcon(fileIconName(node.name), 16)}{/if}
      </span>
      <span class="truncate">{node.name}</span>
    </button>
  {/if}
{/snippet}
