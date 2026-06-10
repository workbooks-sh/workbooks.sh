// Commit helpers shared by the crew console + the member profile. One home for
// the tag→color map (DESIGN §4.8: tag-color the message by type) and the
// relative-time formatter, so neither drifts.

// the newsroom's commit types — the leading `<tag>:` of a message. Color is the
// ONE wire-blue + the two market semantics + the section accents (DESIGN §3:
// no freelance colors). desk/edit lean monochrome; the verbs that PRODUCE the
// page (research/write/publish) carry the accents.
const TYPES = {
  desk:     { color: 'var(--ink-3)' },     // assignment — quiet
  assigned: { color: 'var(--ink-3)' },
  research: { color: 'var(--sec-policy)' },// plum — the evidence pass
  write:    { color: 'var(--wire)' },      // wire blue — the writing
  draft:    { color: 'var(--wire)' },
  edit:     { color: 'var(--ink-2)' },     // the gate — near-ink
  publish:  { color: 'var(--up)' },        // up-green — it shipped
};

// classify a message → { tag, color, body } (body = message minus the tag).
export function classify(msg = '') {
  const m = /^([a-z]+):\s*/i.exec(msg);
  const tag = m ? m[1].toLowerCase() : null;
  const t = tag && TYPES[tag];
  return {
    tag,
    color: t ? t.color : 'var(--ink-3)',
    body: m ? msg.slice(m[0].length) : msg,
  };
}

// relative time from a unix-seconds ts (the commit feed's optional ts). Falls
// back to a passed-through string (the specimen wire uses HH:MM directly).
export function rel(ts) {
  if (ts == null) return '';
  if (typeof ts === 'string') return ts;
  const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (s < 60) return s + 's ago';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}
