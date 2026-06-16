// Waldo in-chat components — message render contract.
//
// One home for: "is this message org?" + "split an org message into
// prose + inline component segments". See desktop/docs/waldo-inchat-
// components.md. Prose is rendered by the EXISTING $lib/org-renderer
// OQL-WASM pipeline; component segments are forwarded to the real
// <work-gen-block> SDK element (via WorkGenBlock.svelte), which reads
// structured props/body — we never {@html} raw LLM output.

/** Leading marker line that opts a message into org rendering. */
const ORG_MARKER = /^#\+RENDER:\s*org\s*$/im;

export type RenderMode = "plain" | "org";

/** Decide how an assistant message renders. Default is plain (today's
 *  behavior) — only the explicit marker switches to org, so nothing
 *  regresses. Stable from the first streamed line. */
export function renderMode(text: string): RenderMode {
  return ORG_MARKER.test(text.slice(0, 64)) ? "org" : "plain";
}

/** A component authored inline as `#+begin_src component :type … #+end_src`. */
export interface ComponentSegment {
  kind: "component";
  type: string;
  props: Record<string, string>;
  body: string;
}

/** A run of plain org prose to hand to renderOrg(). */
export interface OrgSegment {
  kind: "org";
  source: string;
}

export type Segment = OrgSegment | ComponentSegment;

// `#+begin_src component <header-args>` … `#+end_src`. Case-insensitive,
// tolerant of indentation the LLM might add.
const BLOCK_RE =
  /^[ \t]*#\+begin_src[ \t]+component\b([^\n]*)\n([\s\S]*?)^[ \t]*#\+end_src[ \t]*$/gim;

/** Split an org message into prose + component segments, in order.
 *  The org marker line is stripped from the first prose segment. */
export function splitOrg(text: string): Segment[] {
  const src = text.replace(ORG_MARKER, "").replace(/^\n+/, "");
  const segments: Segment[] = [];
  let last = 0;
  for (const m of src.matchAll(BLOCK_RE)) {
    const start = m.index ?? 0;
    if (start > last) {
      const prose = src.slice(last, start);
      if (prose.trim()) segments.push({ kind: "org", source: prose });
    }
    const { type, props } = parseHeaderArgs(m[1]);
    segments.push({
      kind: "component",
      type: type || "callout",
      props,
      body: m[2].replace(/\n+$/, ""),
    });
    last = start + m[0].length;
  }
  if (last < src.length) {
    const prose = src.slice(last);
    if (prose.trim()) segments.push({ kind: "org", source: prose });
  }
  // A marker-only message with no body still renders as (empty) org.
  if (segments.length === 0 && src.trim()) {
    segments.push({ kind: "org", source: src });
  }
  return segments;
}

/** Parse Babel-style header args (`:type callout :tone info`). The
 *  first `:type` value is pulled out; the rest become props. Values
 *  run until the next ` :key` or end of line. */
function parseHeaderArgs(header: string): {
  type: string;
  props: Record<string, string>;
} {
  const props: Record<string, string> = {};
  const re = /:([a-zA-Z][\w-]*)[ \t]+([^:\n][^\n]*?)(?=[ \t]+:[a-zA-Z]|$)/g;
  for (const m of header.matchAll(re)) {
    props[m[1].toLowerCase()] = m[2].trim();
  }
  const type = props.type ?? "";
  delete props.type;
  return { type, props };
}
