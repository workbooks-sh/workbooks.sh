// Shared terminal store — ONE scrollback that both the WorkTerminal input and the toolbar (Run/Weave) feed,
// so those buttons run REAL commands instead of just opening the panel. exec() is the single path into
// dock.shell; the terminal component is a view of `term.lines`.
import { dock } from './dock/index.js'
import { begin, end } from './activity.svelte.js'

export const term = $state({ lines: [{ kind: 'sys', text: 'washy — workbooks shell (emulated, wasm sandbox). type `help`.' }] })

export async function exec(cmd) {
  const c = String(cmd || '').trim()
  if (!c) return
  term.lines.push({ kind: 'cmd', text: '$ ' + c })
  begin(c.split(/\s+/)[0]) // the footer shows the real command verb while it runs
  try {
    const res = await dock.shell.exec(c)
    for (const ln of res) {
      if (ln.kind === 'clear') term.lines = []
      else term.lines.push({ kind: ln.kind, text: ln.text })
    }
  } finally { end() }
}

export function clear() { term.lines = [] }
