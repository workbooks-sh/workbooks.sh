// A small inline-SVG set in the dashboard's stroke style (1.75, round caps). Not the full ICO map —
// just the glyphs the Studio rail/sidebar needs. currentColor so they inherit text color.
const s = (body) =>
  `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`

export const ICO = {
  spark: s('<path d="M12 3l1.9 5.8L19.8 10l-5.9 1.2L12 17l-1.9-5.8L4.2 10l5.9-1.2L12 3Z"/>'),
  grid: s('<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>'),
  files: s('<path d="M4 6a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6Z"/>'),
  sheet: s('<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M3 15h18M9 3v18M15 3v18"/>'),
  toolbox: s('<rect x="3" y="7" width="18" height="13" rx="2"/><path d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M3 12h18"/>'),
  admin: s('<path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6l7-3Z"/>'),
  chev: s('<path d="M9 6l6 6-6 6"/>'),
  gear: s('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2V21a2 2 0 1 1-4 0v-.1A1.7 1.7 0 0 0 7 19.4a1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0-1.2-2.9H1a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 2.6 7Z"/>'),
  search: s('<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>'),
  plus: s('<path d="M12 5v14M5 12h14"/>'),
  chat: s('<path d="M21 11.5a8.38 8.38 0 0 1-8.5 8.5 8.5 8.5 0 0 1-3.6-.8L3 21l1.9-5.9A8.38 8.38 0 0 1 4 11.5 8.5 8.5 0 0 1 12.5 3 8.38 8.38 0 0 1 21 11.5Z"/>'),
  // list-tree — "open the pages within this app" affordance (revealed on row hover)
  tree: s('<path d="M21 12h-8M21 6h-8M21 18h-8M3 6v4a2 2 0 0 0 2 2h3M3 10v6a2 2 0 0 0 2 2h3"/>'),
  // kind glyphs (Iconoir-style line icons) — color carries the kind, not the shape
  appWindow: s('<rect x="2.5" y="4.5" width="19" height="15" rx="2.5"/><path d="M2.5 9h19M6 6.7h.01M8.5 6.7h.01"/>'),
  agent: s('<rect x="4" y="8" width="16" height="11" rx="2.5"/><path d="M12 8V4.6"/><circle cx="12" cy="3.4" r="1.1"/><path d="M9 13h.01M15 13h.01M9.5 16.2h5"/>'),
  flow: s('<circle cx="6" cy="5.5" r="2"/><circle cx="6" cy="18.5" r="2"/><circle cx="18" cy="12" r="2"/><path d="M8 5.5h4a2 2 0 0 1 2 2v2.5M8 18.5h4a2 2 0 0 0 2-2v-2.5"/>')
}

// kind → line icon + accent color. Chat stays gray; app/agent/workflow each get a hue.
export const KIND_ICON = { chat: ICO.chat, app: ICO.appWindow, agent: ICO.agent, workflow: ICO.flow }
export const KIND_COLOR = {
  chat: 'var(--color-dim)',
  app: 'var(--color-sky)',
  agent: 'var(--color-pause)',
  workflow: 'var(--color-amber)'
}
