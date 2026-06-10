// Section identity (DESIGN.md §3): a 2px tick + mono tag, NOT a tinted card.
// One home for the section→color map so every component agrees.
export const SECTIONS = {
  AI:      { tag: 'AI',      color: 'var(--sec-ai)' },
  MARKETS: { tag: 'MARKETS', color: 'var(--sec-markets)' },
  CHIPS:   { tag: 'CHIPS',   color: 'var(--sec-chips)' },
  POLICY:  { tag: 'POLICY',  color: 'var(--sec-policy)' },
};

export function sectionOf(name) {
  return SECTIONS[name] || { tag: name, color: 'var(--ink)' };
}
