// Section identity (DESIGN.md §4.2/§4.3). Each section: tiny badge (icon + tag),
// tinted wash bg (color at ~10% via color-mix), color text, radius 999,
// padding 3px 8px, mono 9.5px. Page stays monochrome — color appears ONLY here.
// Icons: clean 24-viewBox paths, 12px, currentColor.
export const SECTIONS = {
  AI: {
    tag: 'AI',
    color: '#0a52e0',  // wire blue
    // sparkle / circuit node
    icon: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/><circle cx="12" cy="12" r="3"/></svg>`,
  },
  MARKETS: {
    tag: 'MARKETS',
    color: '#0a7d4f',  // up-green
    // trending line
    icon: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 17 9 11 13 15 21 7"/><polyline points="15 7 21 7 21 13"/></svg>`,
  },
  CHIPS: {
    tag: 'CHIPS',
    color: '#b8860b',  // amber
    // chip outline
    icon: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="1"/><path d="M7 9H5M7 12H5M7 15H5M17 9h2M17 12h2M17 15h2M9 7V5M12 7V5M15 7V5M9 17v2M12 17v2M15 17v2"/></svg>`,
  },
  POLICY: {
    tag: 'POLICY',
    color: '#7a4988',  // plum
    // bank / columns
    icon: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 22h18M3 10h18M5 10V6M9 10V6M13 10V6M17 10V6M19 10V6M21 22v-2a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v2M12 2 3 6h18L12 2z"/></svg>`,
  },
};

export function sectionOf(name) {
  return SECTIONS[name] || { tag: name, color: 'var(--ink)', icon: '' };
}
