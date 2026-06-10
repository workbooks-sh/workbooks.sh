export const insp = $state({ open: false, tab: "elements", log: [], changes: [] });
export function openInsp(tab) { if (tab) insp.tab = tab; insp.open = true; document.documentElement.dataset.insp = "open"; }
export function closeInsp() { insp.open = false; document.documentElement.dataset.insp = "closed"; }
export function logLine(html, cls = "") { insp.log = [...insp.log, { html, cls }]; }
