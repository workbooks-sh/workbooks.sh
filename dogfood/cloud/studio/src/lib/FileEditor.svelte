<script>
  // The Files IDE editor pane: tabs + breadcrumb + a CodeMirror editor themed from the APP's own
  // tokens (paper/ink + pastels) so it matches the rest of the app and follows light/dark. Full height.
  import { fsUi, closeFile, saveFile, markDirty } from './fs.svelte.js'
  import { iconSvgByName } from './icons.js'
  import { vsIcon, fileIconName, isWorkFile } from './file-icons.js'
  import { dock } from './dock/index.js'
  import { EditorView, basicSetup } from 'codemirror'
  import { keymap, hoverTooltip } from '@codemirror/view'
  import { autocompletion } from '@codemirror/autocomplete'
  import { linter, lintGutter } from '@codemirror/lint'
  import { EditorState } from '@codemirror/state'
  import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
  import { tags as t } from '@lezer/highlight'
  import { javascript } from '@codemirror/lang-javascript'
  import { rust } from '@codemirror/lang-rust'
  import { json } from '@codemirror/lang-json'
  import { markdown } from '@codemirror/lang-markdown'
  import { html } from '@codemirror/lang-html'
  import { css } from '@codemirror/lang-css'
  import { elixir } from 'codemirror-lang-elixir'

  const appTheme = EditorView.theme({
    '&': { color: 'var(--color-ink)', backgroundColor: 'var(--color-well)', height: '100%' },
    '.cm-scroller': { fontFamily: 'var(--font-mono)', lineHeight: '1.6' },
    '.cm-content': { caretColor: 'var(--color-ink)' },
    '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--color-ink)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection':
      { backgroundColor: 'color-mix(in srgb, var(--color-sky) 32%, transparent)' },
    '.cm-gutters': { backgroundColor: 'var(--color-well)', color: 'color-mix(in srgb, var(--color-dim) 65%, transparent)', border: 'none' },
    '.cm-lineNumbers .cm-gutterElement': { padding: '0 10px 0 12px' },
    '.cm-activeLine': { backgroundColor: 'color-mix(in srgb, var(--color-ink) 4%, transparent)' },
    '.cm-activeLineGutter': { backgroundColor: 'color-mix(in srgb, var(--color-ink) 5%, transparent)', color: 'var(--color-ink)' },
    '.cm-selectionMatch': { backgroundColor: 'color-mix(in srgb, var(--color-cream) 38%, transparent)' },
    '.cm-matchingBracket, &.cm-focused .cm-matchingBracket': { backgroundColor: 'color-mix(in srgb, var(--color-mint) 40%, transparent)', outline: 'none' },
    '.cm-foldPlaceholder': { backgroundColor: 'transparent', border: 'none', color: 'var(--color-dim)' },
    // lang-lane surfaces (hover · autocomplete · diagnostics) — themed from app tokens
    '.cm-tooltip': { backgroundColor: 'var(--color-card)', border: '1px solid var(--color-line)', borderRadius: '10px', boxShadow: '0 12px 30px rgba(0,0,0,.28)', overflow: 'hidden' },
    '.cm-wb-hover': { padding: '8px 11px', fontFamily: 'var(--font-sans)', fontSize: '12.5px', lineHeight: '1.5', color: 'var(--color-ink)', maxWidth: '340px' },
    '.cm-tooltip.cm-tooltip-autocomplete > ul': { fontFamily: 'var(--font-mono)', fontSize: '12.5px', maxHeight: '14em' },
    '.cm-tooltip.cm-tooltip-autocomplete > ul > li': { padding: '3px 9px', color: 'var(--color-ink)' },
    '.cm-tooltip-autocomplete ul li[aria-selected]': { backgroundColor: 'color-mix(in srgb, var(--color-sky) 30%, transparent)', color: 'var(--color-ink)' },
    '.cm-completionLabel': { color: 'var(--color-ink)' },
    '.cm-completionDetail': { color: 'var(--color-dim)', fontStyle: 'normal' },
    '.cm-completionInfo': { backgroundColor: 'var(--color-card)', border: '1px solid var(--color-line)', borderRadius: '8px', padding: '7px 9px', fontFamily: 'var(--font-sans)', fontSize: '12px', color: 'var(--color-dim)', maxWidth: '280px' },
    '.cm-diagnostic': { fontFamily: 'var(--font-sans)', fontSize: '12.5px', padding: '6px 9px', borderLeftWidth: '3px' },
    '.cm-diagnostic-error': { borderLeftColor: 'var(--color-bad)' },
    '.cm-diagnostic-warning': { borderLeftColor: 'var(--color-amber)' },
    '.cm-lintRange-error': { backgroundImage: 'none', borderBottom: '1.5px wavy var(--color-bad)', textDecoration: 'underline wavy var(--color-bad)' },
    '.cm-lintRange-warning': { textDecoration: 'underline wavy var(--color-amber)' }
  })
  const appHighlight = HighlightStyle.define([
    { tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword], color: 'var(--color-pause)' },
    { tag: [t.string, t.special(t.string), t.regexp], color: 'var(--color-bloomd)' },
    { tag: [t.number, t.bool, t.atom, t.null, t.unit], color: 'var(--color-amber)' },
    { tag: [t.comment, t.lineComment, t.blockComment, t.meta], color: 'var(--color-dim)', fontStyle: 'italic' },
    { tag: [t.typeName, t.className, t.namespace, t.changed], color: 'var(--color-amber)' },
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.labelName], color: 'var(--color-ink)', fontWeight: '600' },
    { tag: [t.variableName, t.propertyName, t.attributeValue], color: 'var(--color-ink)' },
    { tag: [t.attributeName], color: 'var(--color-amber)' },
    { tag: [t.tagName], color: 'var(--color-bloomd)' },
    { tag: [t.punctuation, t.bracket, t.separator, t.operator, t.derefOperator], color: 'color-mix(in srgb, var(--color-dim) 85%, var(--color-ink))' },
    { tag: [t.heading], color: 'var(--color-ink)', fontWeight: '700' },
    { tag: [t.link, t.url], color: 'var(--color-pause)', textDecoration: 'underline' },
    { tag: t.emphasis, fontStyle: 'italic' },
    { tag: t.strong, fontWeight: '700' },
    { tag: t.invalid, color: 'var(--color-bad)' }
  ])
  const appEditor = [appTheme, syntaxHighlighting(appHighlight)]

  // ── the LANG LANE — completion · diagnostics · hover, all sourced from dock.lang.* (the host language
  // capability). Local provider answers in-browser today; a wasm LSP server fulfills the same calls later. ──
  async function completeSource(ctx) {
    const word = ctx.matchBefore(/[\w.]*/)
    if (!word || (word.from === word.to && !ctx.explicit)) return null
    const items = await dock.lang.complete(fsUi.active?.path, { text: ctx.state.doc.toString(), prefix: word.text })
    if (!items?.length) return null
    return { from: word.from, options: items.map((i) => i.insert
      ? { label: i.label, type: i.type, info: i.info, apply: i.insert }
      : { label: i.label, type: i.type, info: i.info }) }
  }
  const workComplete = autocompletion({ override: [completeSource], icons: false })
  const workLint = linter(async (view) =>
    (await dock.lang.diagnostics(fsUi.active?.path, view.state.doc.toString())) || [], { delay: 350 })
  const wordAt = (state, pos) => {
    let s = pos, e = pos
    while (s > 0 && /\w/.test(state.doc.sliceString(s - 1, s))) s--
    while (e < state.doc.length && /\w/.test(state.doc.sliceString(e, e + 1))) e++
    return { from: s, to: e, text: state.doc.sliceString(s, e) }
  }
  const workHover = hoverTooltip(async (view, pos) => {
    const w = wordAt(view.state, pos)
    if (!w.text) return null
    const md = await dock.lang.hover(fsUi.active?.path, w.text)
    if (!md) return null
    return { pos: w.from, end: w.to, above: true, create: () => {
      const dom = document.createElement('div')
      dom.className = 'cm-wb-hover'
      dom.textContent = md.replace(/\*\*/g, '').replace(/`/g, '')
      return { dom }
    } }
  })
  const langLane = [workComplete, workLint, lintGutter(), workHover]

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
      default: return []
    }
  }

  // ── multi-format viewing — route by extension. text/code → CodeMirror; everything else → a viewer.
  // Images/SVG/PDF render natively (zero deps; the browser fetches /cloud/raw with the session cookie).
  // CSV parses in-line; spreadsheets lazy-load SheetJS (a separate chunk, only when an .xlsx opens).
  const VIEW = { png: 'image', jpg: 'image', jpeg: 'image', gif: 'image', webp: 'image', avif: 'image', bmp: 'image', ico: 'image',
    svg: 'svg', pdf: 'pdf', csv: 'csv', tsv: 'csv', xlsx: 'sheet', xls: 'sheet' }
  const viewKind = (name = '') => VIEW[name.toLowerCase().split('.').pop()] || 'text'
  const kind = $derived(viewKind(fsUi.active?.name))
  const rawUrl = $derived(fsUi.active?.path ? '/cloud/raw?path=' + encodeURIComponent(fsUi.active.path) : '')

  // tiny CSV/TSV parser (handles quoted fields + embedded delimiters/newlines) → rows[][]
  function parseDelim(text, d) {
    const rows = []; let row = [], cur = '', q = false
    for (let i = 0; i < text.length; i++) {
      const c = text[i]
      if (q) { if (c === '"') { if (text[i + 1] === '"') { cur += '"'; i++ } else q = false } else cur += c }
      else if (c === '"') q = true
      else if (c === d) { row.push(cur); cur = '' }
      else if (c === '\n') { row.push(cur); rows.push(row); row = []; cur = '' }
      else if (c !== '\r') cur += c
    }
    if (cur !== '' || row.length) { row.push(cur); rows.push(row) }
    return rows.filter((r) => r.length > 1 || (r[0] || '') !== '')
  }
  const csvRows = $derived(kind === 'csv' && fsUi.active?.content != null
    ? parseDelim(fsUi.active.content, fsUi.active.name.toLowerCase().endsWith('.tsv') ? '\t' : ',') : [])

  // spreadsheet → lazy SheetJS (separate chunk); fetch bytes, parse the first sheet to rows
  let sheetRows = $state(null), sheetErr = $state(null)
  $effect(() => {
    const k = kind, url = rawUrl
    sheetRows = null; sheetErr = null
    if (k !== 'sheet' || !url) return
    ;(async () => {
      try {
        const XLSX = await import('xlsx')
        const buf = await (await fetch(url, { credentials: 'same-origin' })).arrayBuffer()
        const wb = XLSX.read(buf, { type: 'array' })
        sheetRows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '' })
      } catch (e) { sheetErr = 'Could not open this spreadsheet.' }
    })()
  })

  let host
  let view
  let suppress = false // don't flag dirty when WE swap the doc on tab switch
  function save() { if (fsUi.active && view) saveFile(fsUi.active, view.state.doc.toString()) }
  // mark the active file dirty as the doc changes (so the tab shows an unsaved dot)
  const dirtyTracker = EditorView.updateListener.of((u) => { if (u.docChanged && !suppress && fsUi.active) markDirty(fsUi.active) })
  const saveKey = keymap.of([{ key: 'Mod-s', preventDefault: true, run: () => { save(); return true } }])
  // CodeMirror is created only for the text host (which mounts only for text files); recreated if it remounts.
  $effect(() => {
    if (!host) return
    const v = new EditorView({ parent: host })
    view = v
    return () => { v.destroy(); view = undefined }
  })
  $effect(() => {
    const a = fsUi.active
    if (!view || viewKind(a?.name) !== 'text') return
    suppress = true
    view.setState(EditorState.create({ doc: a?.content ?? '', extensions: [basicSetup, saveKey, dirtyTracker, langFor(a?.name), appEditor, langLane] }))
    a && (a.dirty = false)
    suppress = false
  })
</script>

<div class="h-full min-w-0 flex flex-col" style="background:var(--color-well)">
  <!-- tab bar -->
  <div class="flex items-stretch h-[46px] flex-none border-b border-line overflow-x-auto" style="background:var(--color-paper)">
    {#each fsUi.tabs as tab}
      <button onclick={() => (fsUi.active = tab)}
        class="group/tab flex items-center gap-2 px-3.5 border-r border-line text-[12.5px] whitespace-nowrap hoverwash
          {fsUi.active === tab ? 'text-ink' : 'text-dim hover:text-ink'}"
        style={fsUi.active === tab ? 'background:var(--color-well);box-shadow:inset 0 -2px 0 var(--color-sky)' : ''}>
        <span class="grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]" style={isWorkFile(tab.name) ? 'color:var(--color-bloomd)' : ''}>
          {#if isWorkFile(tab.name)}{@html iconSvgByName('journal-page', 15)}{:else}{@html vsIcon(fileIconName(tab.name), 15)}{/if}
        </span>
        {tab.name}
        {#if tab.dirty}<span class="w-1.5 h-1.5 rounded-full flex-none" style="background:var(--color-sky)" title="Unsaved"></span>{/if}
        <span class="grid place-items-center rounded opacity-0 group-hover/tab:opacity-100 hover:bg-[color-mix(in_srgb,var(--color-ink)_12%,transparent)] [&>svg]:w-[13px] [&>svg]:h-[13px]"
          role="button" tabindex="-1" onclick={(e) => { e.stopPropagation(); closeFile(tab) }}>{@html iconSvgByName('xmark', 13)}</span>
      </button>
    {/each}
  </div>

  {#if fsUi.active}
    <div class="flex items-center gap-1.5 px-4 h-[30px] flex-none text-[11.5px] text-dim font-mono border-b border-line" style="background:var(--color-well)">
      {fsUi.active.path.replace(/^\//, '').split('/').join('  ›  ')}
      <span class="flex-1"></span>
      {#if kind === 'text'}
        <button onclick={save} disabled={!fsUi.active.dirty}
          class="flex items-center gap-1 px-2 py-0.5 rounded text-[11px] disabled:opacity-40 hover:bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] [&>svg]:w-3 [&>svg]:h-3"
          title="Save (⌘S)">{@html iconSvgByName('floppy-disk', 12)} {fsUi.active.dirty ? 'Save' : 'Saved'}</button>
      {:else}
        <a href={rawUrl} download={fsUi.active.name} class="flex items-center gap-1 px-2 py-0.5 rounded text-[11px] text-dim hover:text-ink [&>svg]:w-3 [&>svg]:h-3" title="Download">{@html iconSvgByName('download', 12)} Download</a>
      {/if}
    </div>

    {#if kind === 'text'}
      <div bind:this={host} class="flex-1 min-h-0 overflow-hidden text-[13px]"></div>
    {:else if kind === 'image' || kind === 'svg'}
      <!-- checkerboard so transparency reads; native <img> (browser fetches /cloud/raw w/ session cookie) -->
      <div class="flex-1 min-h-0 overflow-auto grid place-items-center p-6"
        style="background:repeating-conic-gradient(color-mix(in srgb,var(--color-ink) 5%,transparent) 0% 25%, transparent 0% 50%) 50%/22px 22px">
        <img src={rawUrl} alt={fsUi.active.name} class="max-w-full max-h-full object-contain" style="box-shadow:0 6px 24px rgba(0,0,0,.18)" />
      </div>
    {:else if kind === 'pdf'}
      <iframe src={rawUrl} title={fsUi.active.name} class="flex-1 min-h-0 w-full" style="border:0;background:var(--color-paper)"></iframe>
    {:else if kind === 'csv' || kind === 'sheet'}
      {@const rows = kind === 'csv' ? csvRows : sheetRows}
      <div class="flex-1 min-h-0 overflow-auto">
        {#if kind === 'sheet' && sheetErr}
          <div class="grid place-items-center h-full text-dim text-[13px]">{sheetErr}</div>
        {:else if kind === 'sheet' && !rows}
          <div class="grid place-items-center h-full text-dim text-[13px] animate-pulse">opening spreadsheet…</div>
        {:else if !rows || !rows.length}
          <div class="grid place-items-center h-full text-dim text-[13px]">empty</div>
        {:else}
          <table class="text-[12.5px] border-collapse w-max min-w-full font-mono">
            <tbody>
              {#each rows as r, ri}
                <tr class={ri === 0 ? 'sticky top-0' : ''}>
                  <td class="px-2 py-1 text-right text-dim/40 select-none border-r border-line tabular-nums" style="background:var(--color-paper)">{ri + 1}</td>
                  {#each r as cell}
                    <td class="px-3 py-1 border-r border-b border-line whitespace-pre {ri === 0 ? 'font-semibold text-ink' : 'text-ink/90'}" style={ri === 0 ? 'background:var(--color-card)' : ''}>{cell}</td>
                  {/each}
                </tr>
              {/each}
            </tbody>
          </table>
        {/if}
      </div>
    {/if}
  {:else}
    <div class="flex-1 grid place-items-center text-dim text-[13px]">No file open</div>
  {/if}
</div>
