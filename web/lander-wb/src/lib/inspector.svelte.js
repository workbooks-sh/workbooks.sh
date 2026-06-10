export const insp = $state({ open: false, tab: "elements", log: [], changes: [] });
export function openInsp(tab) { if (tab) insp.tab = tab; insp.open = true; document.documentElement.dataset.insp = "open"; }
export function closeInsp() { insp.open = false; document.documentElement.dataset.insp = "closed"; }
export function logLine(html, cls = "") { const e = { html, cls }; insp.log = [...insp.log, e]; return e; }
export function logUpdate(e, html) { e.html = html; insp.log = [...insp.log]; }
