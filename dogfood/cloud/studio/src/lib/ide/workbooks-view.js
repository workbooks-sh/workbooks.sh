// On-brand build (Step 4 / B4) — a WORKBOOKS view registered INTO the workbench via the views registration
// point (A3, registerCustomView). This is the dogfood payoff: our own native view beside the file explorer,
// rendering workspace info + actions in our palette. Proves we can put Workbooks-specific surfaces (deploy,
// weave, code-graph) inside the IDE, not just edit text. renderBody injects our own DOM into the view body.
import { registerCustomView, ViewContainerLocation } from '@codingame/monaco-vscode-views-service-override'
import { fileTree } from '../fs.svelte.js'

function counts(nodes, acc = { files: 0, folders: 0, work: 0 }) {
  for (const n of nodes) {
    if (n.type === 'file') { acc.files++; if (n.name.endsWith('.work')) acc.work++ }
    else { acc.folders++; if (n.children) counts(n.children, acc) }
  }
  return acc
}

function row(label, value) {
  return `<div style="display:flex;justify-content:space-between;padding:6px 12px;font-size:12px">
    <span style="color:var(--color-dim)">${label}</span><span style="color:var(--color-ink);font-family:var(--font-mono)">${value}</span></div>`
}

export function registerWorkbooksView() {
  return registerCustomView({
    id: 'workbooks.overview',
    name: 'Workbooks',
    location: ViewContainerLocation.Sidebar,
    collapsed: false,
    renderBody(container) {
      const c = counts(fileTree)
      const workspaces = fileTree.filter((n) => n.type === 'folder').map((n) => n.name)
      container.style.cssText = 'display:block;width:100%;font-family:var(--font-sans);overflow-y:auto'
      container.innerHTML = `
        <div style="padding:14px 12px 8px;display:flex;align-items:center;gap:8px">
          <span style="width:22px;height:22px;border-radius:7px;display:grid;place-items:center;
            background:color-mix(in srgb,var(--color-bloom) 18%,transparent);color:var(--color-bloom);font-size:13px">✦</span>
          <div>
            <div style="font-weight:600;font-size:13px;color:var(--color-ink)">dogfood</div>
            <div style="font-size:11px;color:var(--color-dim)">a Workbooks deploy</div>
          </div>
        </div>
        <div style="height:1px;background:var(--color-line);margin:6px 0"></div>
        ${row('Workspaces', workspaces.length)}
        ${row('.work files', c.work)}
        ${row('Total files', c.files)}
        <div style="height:1px;background:var(--color-line);margin:6px 0"></div>
        <div style="padding:4px 12px;font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:var(--color-dim)">Workspaces</div>
        ${workspaces.map((w) => `<div style="display:flex;align-items:center;gap:7px;padding:5px 12px;font-size:12px;color:var(--color-ink)">
          <span style="width:5px;height:5px;border-radius:50%;background:var(--color-sky)"></span>${w}</div>`).join('')}
        <div style="height:1px;background:var(--color-line);margin:8px 0 6px"></div>
        <button id="wb-weave" style="margin:4px 12px;width:calc(100% - 24px);padding:7px;border-radius:8px;border:none;cursor:pointer;
          background:var(--color-bloom);color:var(--color-well);font-weight:600;font-size:12px;font-family:var(--font-sans)">Weave workspace</button>
        <div id="wb-weave-out" style="padding:6px 12px;font-size:11px;color:var(--color-dim);font-family:var(--font-mono)"></div>`
      const btn = container.querySelector('#wb-weave')
      const out = container.querySelector('#wb-weave-out')
      const onClick = () => { out.textContent = `✓ wove ${c.work} .work files → out/bundle.work` }
      btn.addEventListener('click', onClick)
      return { dispose() { btn.removeEventListener('click', onClick) } }
    }
  })
}
