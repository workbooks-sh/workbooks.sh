/**
 * Split an assistant message into Markdown prose + inline `<work-*>` element
 * segments, in order. Agents emit components as plain HTML
 * (`<work-tag attr="v">body</work-tag>` or self-closing) — the chat renders the
 * prose as Markdown and mounts each `<work-*>` as the REAL custom element
 * (structured attrs + textContent, never `{@html}` of raw model output).
 */
export interface ComponentSegment {
  kind: "component";
  tag: string;
  attrs: Record<string, string>;
  body: string;
}

export interface TextSegment {
  kind: "text";
  source: string;
}

export type Segment = TextSegment | ComponentSegment;

// An inline `<work-*>` element: paired (with a body) or self-closing.
const EL_RE =
  /<(work-[a-z][\w-]*)((?:\s+[a-zA-Z][\w-]*(?:=(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(?:\/>|>([\s\S]*?)<\/\1\s*>)/g;

export function splitComponents(text: string): Segment[] {
  const segments: Segment[] = [];
  let last = 0;

  for (const m of text.matchAll(EL_RE)) {
    const start = m.index ?? 0;
    if (start > last) {
      const prose = text.slice(last, start);
      if (prose.trim()) segments.push({ kind: "text", source: prose });
    }
    segments.push({
      kind: "component",
      tag: m[1],
      attrs: parseAttrs(m[2] ?? ""),
      body: (m[3] ?? "").trim(),
    });
    last = start + m[0].length;
  }

  if (last < text.length) {
    const prose = text.slice(last);
    if (prose.trim()) segments.push({ kind: "text", source: prose });
  }

  if (segments.length === 0 && text.trim()) {
    segments.push({ kind: "text", source: text });
  }

  return segments;
}

/** Parse `attr="value"` pairs from a tag's attribute string. */
function parseAttrs(s: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  const re = /([a-zA-Z][\w-]*)(?:=(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
  for (const m of s.matchAll(re)) {
    if (!m[1]) continue;
    attrs[m[1]] = m[2] ?? m[3] ?? m[4] ?? "";
  }
  return attrs;
}
