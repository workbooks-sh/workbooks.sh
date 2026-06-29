// Tiny notification primitive — the workbench's status-message surface. `vscode.window.showInformationMessage`
// (via the ext-host shim) routes here, so an extension command's effect is actually visible. Auto-dismisses.
let _id = 0
export const toasts = $state([])

export function pushToast(msg, kind = 'info') {
  const id = ++_id
  toasts.push({ id, msg, kind })
  setTimeout(() => { const i = toasts.findIndex((t) => t.id === id); if (i >= 0) toasts.splice(i, 1) }, 3400)
}
