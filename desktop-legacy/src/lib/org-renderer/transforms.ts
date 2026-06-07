// wb-i38o.9 — org-render post-transforms.
//
// Duplicates the transforms in packages/workbooks/spikes/oql-container/
// src/build.mjs verbatim — same visual contract, so when authors look
// at a workbook .html from the spike and an .org rendered live in the
// desktop, the chrome (status pills, tag chips, properties drawers,
// GAP asides) matches. If the spike updates these, we sync them here;
// the spike is a build-time tool, this is a runtime component, but
// the visual output should agree.

export interface ParsedHeadline {
  level: number;
  state?: string | null;
  tags?: string[];
  title?: string;
}

export interface DrawerProperty {
  key: string;
  value: string;
}

export interface HeadingWithProps extends ParsedHeadline {
  properties: DrawerProperty[];
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// orgize emits `<!-- GAP: ... -->` HTML comments for the `# GAP: ...`
// notes the OQL authors leave inline. Surface them as visible callouts.
export function transformGapComments(html: string): string {
  return html.replace(
    /<!--\s*GAP([^>]*?(?:>[^>]*?)*?)\s*-->/g,
    (_match, body) => {
      const cleaned = String(body)
        .replace(/^\s*:?\s*/, "")
        .replace(/-->$/, "")
        .replace(/^\(([^)]+)\)\s*/, "<strong>($1)</strong> ")
        .trim();
      return `<aside class="gap-note"><span class="gap-label">GAP</span><div>${cleaned}</div></aside>`;
    },
  );
}

interface PropertyDrawer {
  properties: DrawerProperty[];
  srcOffset: number;
}

function extractPropertiesDrawers(src: string): PropertyDrawer[] {
  const out: PropertyDrawer[] = [];
  const re = /^[ \t]*:PROPERTIES:\s*\n([\s\S]*?)^[ \t]*:END:\s*$/gm;
  let mm: RegExpExecArray | null;
  while ((mm = re.exec(src)) !== null) {
    const block = mm[1];
    const props: DrawerProperty[] = [];
    for (const line of block.split("\n")) {
      const kv = line.match(/^\s*:([A-Z_][A-Z0-9_]*):\s*(.*?)\s*$/);
      if (kv) props.push({ key: kv[1], value: kv[2] });
    }
    if (props.length) out.push({ properties: props, srcOffset: mm.index });
  }
  return out;
}

interface HeadingOffset {
  offset: number;
  level: number;
  state: string | null;
  titleLine: string;
}

function findHeadingOffsets(src: string): HeadingOffset[] {
  const out: HeadingOffset[] = [];
  const re =
    /^(\*+)\s+(?:(TODO|NEXT|IN_PROGRESS|WAIT|DONE|CANCELLED|BLOCKED)\s+)?(.+?)$/gm;
  let mm: RegExpExecArray | null;
  while ((mm = re.exec(src)) !== null) {
    out.push({
      offset: mm.index,
      level: mm[1].length,
      state: mm[2] ?? null,
      titleLine: mm[3],
    });
  }
  return out;
}

export function buildHeadingsWithProperties(
  src: string,
  parsedHeadlines: ParsedHeadline[],
): HeadingWithProps[] {
  const offsets = findHeadingOffsets(src);
  const drawers = extractPropertiesDrawers(src);
  const out: HeadingWithProps[] = [];
  for (let i = 0; i < parsedHeadlines.length; i++) {
    const h = parsedHeadlines[i];
    const here = offsets[i];
    const next = offsets[i + 1];
    const drawer = drawers.find(
      (d) =>
        here !== undefined &&
        d.srcOffset > here.offset &&
        (next === undefined || d.srcOffset < next.offset),
    );
    out.push({
      ...h,
      properties: drawer?.properties ?? [],
    });
  }
  return out;
}

// See build.mjs:stripStatePrefix — orgize's `_X` → `<sub>X</sub>` transform
// mangles `IN_PROGRESS` into `IN<sub>PROGRESS</sub>`. Strip the state
// keyword (literal or mangled) off the heading body so the pill carries
// it instead.
function stripStatePrefix(body: string, state: string | null | undefined): string {
  if (!state) return body;
  const literal = state + " ";
  if (body.startsWith(literal)) return body.slice(literal.length);
  if (state.includes("_")) {
    const [head, ...rest] = state.split("_");
    const subPattern = `${head}<sub>${rest.join("_")}</sub> `;
    if (body.startsWith(subPattern)) return body.slice(subPattern.length);
  }
  return body;
}

function tagKind(t: string): string {
  if (/^@/.test(t)) return "context";
  if (/^wb-/.test(t)) return "issue";
  if (["agent", "validator", "plan", "stage", "review"].includes(t))
    return "role";
  if (["registry", "slot", "reference"].includes(t)) return "meta";
  return "default";
}

export function injectHeadingChrome(
  html: string,
  headings: HeadingWithProps[],
): string {
  let idx = 0;
  return html.replace(
    /<(h[1-6])(\s[^>]*)?>([\s\S]*?)<\/\1>/g,
    (match, tag, attrs, body) => {
      if (idx >= headings.length) return match;
      const h = headings[idx];
      idx++;
      const text = String(body)
        .replace(/<[^>]+>/g, "")
        .trim();
      if (!text) return match;
      const statePill = h.state
        ? `<span class="status status-${h.state.toLowerCase()}">${h.state.replace("_", " ")}</span>`
        : "";
      const tagChips =
        h.tags && h.tags.length
          ? `<span class="tags">${h.tags
              .map(
                (t) =>
                  `<span class="tag tag-${tagKind(t)}">${escapeHtml(t)}</span>`,
              )
              .join("")}</span>`
          : "";
      let cleanBody = String(body).replace(/\s+$/, "");
      cleanBody = stripStatePrefix(cleanBody, h.state);
      const propsBlock =
        h.properties && h.properties.length
          ? `<details class="props"><summary>${h.properties.length} ${
              h.properties.length === 1 ? "property" : "properties"
            }</summary><dl>${h.properties
              .map(
                (p) =>
                  `<dt>${escapeHtml(p.key)}</dt><dd>${escapeHtml(p.value)}</dd>`,
              )
              .join("")}</dl></details>`
          : "";
      return `<${tag}${attrs ?? ""}>${statePill}${cleanBody}${tagChips}</${tag}>${propsBlock}`;
    },
  );
}
