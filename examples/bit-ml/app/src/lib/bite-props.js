// Adapt a manifest row (stories.json shape) into the props the Bite / WireLead
// components expect. One home for the mapping so every view agrees (DRY).
//   row.byline { writer, research:[], editor }  →  Byline props
//   row.sources [{label,url}]                    →  ['label', …] (Bite shows labels)
// The byline writer becomes { name, role:'writer' } so the Byline reads
// "by <name> (writer)" per DESIGN.md §4.7.

export function biteProps(row) {
  return {
    slug: row.slug,
    section: row.section,
    time: row.time,
    read: row.read,
    head: row.head,
    dek: row.dek,
    status: row.status === 'live' ? 'live' : 'unread',
    sources: (row.sources || []).map((s) => s.label),
    byline: bylineProps(row.byline),
  };
}

export function leadProps(row) {
  return {
    section: row.section,
    dateline: `${row.time} · ${row.date}`,
    head: row.head,
    dek: row.dek,
    sources: (row.sources || []).map((s) => s.label),
    byline: bylineProps(row.byline),
  };
}

export function bylineProps(b) {
  if (!b) return undefined;
  return {
    writer: { name: b.writer, role: 'writer' },
    research: b.research || [],
    editor: b.editor,
  };
}
