<script>
  // Auth terminal — the OAuth path. We DON'T broker OAuth: instead we drop the user into an interactive
  // terminal on the machine and they run the CLI's own `login` (gh auth login, railway login, …), exactly as
  // they would locally. The CLI authenticates THAT machine — no vendored OAuth pipeline, no us holding tokens.
  // (Security note: in production this runs against a per-tenant sandbox shell; the device-code flow below is a
  // faithful simulation of the real CLI handshake for the demo.) Slides up as a footer over the content pane.
  import { tick } from 'svelte'
  import { ui } from './data.svelte.js'
  import { toolkits } from './toolkits.svelte.js'
  import { iconSvgByName } from './icons.js'

  const t = $derived(toolkits.find((x) => x.id === ui.authTerminal))

  let lines = $state([])
  let input = $state('')
  let phase = $state('cmd') // 'cmd' → awaiting the login command · 'await' → awaiting Enter after browser · 'done'
  let box
  const CODE = 'WB42-CLI9'

  // (re)seed the session each time a different toolkit's terminal opens
  let lastId = null
  $effect(() => {
    if (!t || t.id === lastId) return
    lastId = t.id
    phase = t.connected ? 'done' : 'cmd'
    input = t.connected ? '' : t.loginCmd || ''
    lines = t.connected
      ? [{ t: `✓ ${t.name} is already authenticated on this machine.`, c: 'var(--color-mint)' }]
      : [
          { t: `Authenticating ${t.name}. Run the CLI's own login below — it authenticates this machine.`, c: 'var(--color-dim)' },
          { t: '', c: '' }
        ]
  })

  async function scroll() { await tick(); if (box) box.scrollTop = box.scrollHeight }
  function push(t_, c = 'var(--color-ink)') { lines = [...lines, { t: t_, c }]; scroll() }

  function submit() {
    const cmd = input.trim()
    if (phase === 'done') return
    if (phase === 'cmd') {
      if (!cmd) return
      push(`~ $ ${cmd}`, 'var(--color-ink)')
      input = ''
      // simulate the CLI's device-code handshake
      setTimeout(() => push('! First copy your one-time code:', 'var(--color-peach)'), 200)
      setTimeout(() => push(`    ${CODE}`, 'var(--color-sky)'), 400)
      setTimeout(() => push(`  Press Enter to open the browser at ${t.hosts?.[0] || 'the provider'}…`, 'var(--color-dim)'), 600)
      setTimeout(() => { phase = 'await' }, 650)
      return
    }
    if (phase === 'await') {
      push('  Opened browser · waiting for authorisation…', 'var(--color-dim)')
      setTimeout(() => push(`✓ Authentication complete — ${t.name} authenticated on this machine.`, 'var(--color-mint)'), 900)
      setTimeout(() => { t.connected = true; phase = 'done' }, 950)
    }
  }
  function onKey(e) {
    if (e.key === 'Enter') { e.preventDefault(); submit() }
    if (e.key === 'Escape') ui.authTerminal = null
  }
  function close() { ui.authTerminal = null }
</script>

{#if t}
  <aside class="fixed bottom-0 left-[334px] right-0 z-40 h-[320px] bg-paper border-t border-line shadow-2xl flex flex-col">
    <header class="flex items-center gap-2 px-4 h-[46px] border-b border-line flex-none">
      <span class="[&>svg]:w-4 [&>svg]:h-4 text-dim">{@html iconSvgByName('terminal', 16)}</span>
      <span class="font-display font-semibold text-[13.5px]">Authenticate {t.name}</span>
      <span class="text-dim text-[11.5px] font-mono">interactive terminal · authenticates this machine</span>
      <span class="flex-1"></span>
      {#if phase === 'done'}<span class="text-[11px] flex items-center gap-1 [&>svg]:w-3.5 [&>svg]:h-3.5" style="color:var(--color-mint)">{@html iconSvgByName('check', 13)}connected</span>{/if}
      <button aria-label="Close" onclick={close}
        class="w-7 h-7 grid place-items-center text-dim hover:text-ink rounded-lg border border-line [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('xmark', 15)}</button>
    </header>

    <div bind:this={box} class="flex-1 overflow-y-auto px-4 py-3 font-mono text-[12.5px] leading-relaxed" style="background:#0b0d10">
      {#each lines as l}<div style="color:{l.c}" class="whitespace-pre-wrap min-h-[1em]">{l.t}</div>{/each}
      {#if phase !== 'done'}
        <div class="flex items-center gap-2 mt-1">
          <span style="color:var(--color-mint)">~ $</span>
          <!-- svelte-ignore a11y_autofocus -->
          <input bind:value={input} onkeydown={onKey} autofocus spellcheck="false" autocomplete="off"
            class="flex-1 bg-transparent border-0 outline-none text-ink font-mono text-[12.5px]"
            placeholder={phase === 'await' ? 'press Enter once authorised…' : ''} />
        </div>
      {/if}
    </div>

    <footer class="px-4 py-2 border-t border-line flex items-center gap-2 flex-none text-[11px] text-dim">
      <span class="flex items-center gap-1 [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('shield', 13)}</span>
      Runs in this machine's sandbox shell — the CLI logs itself in, we never see your credentials.
    </footer>
  </aside>
{/if}
