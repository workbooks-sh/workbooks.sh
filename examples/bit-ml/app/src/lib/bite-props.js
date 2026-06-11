// Adapt a manifest row (stories.json shape) into the props the Bite / WireLead
// components expect. One home for the mapping so every view agrees (DRY).
//   row.byline { writer, research:[], editor }  →  Byline props
//   row.sources [{label,url}]                    →  ['label', …] (Bite shows labels)
// The byline writer becomes { name, role:'writer' } so the Byline reads
// "by <name> (writer)" per DESIGN.md §4.7.
import { imageUrl } from './stories.svelte.js';

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
    // banner THUMBNAIL: passed through; the Bite renders it only when the view
    // asks for the FEATURED variant (front-page grid §4.4). Resolved here so
    // workbook mode gets the inlined data-URI (DRY — one image home).
    banner: row.banner ? imageUrl(row.banner) : null,
    bannerAlt: row.bannerAlt ?? '',
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
    // banner image: passed through to WireLead (§4.5 note 3), resolved for
    // workbook mode (inline data-URI) via imageUrl
    banner: row.banner ? imageUrl(row.banner) : null,
    bannerAlt: row.bannerAlt ?? '',
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
