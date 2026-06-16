/**
 * icons — the universal icon library as an agent-facing CLI (wb-5fl.16).
 *
 * One CLI resolves the project-wide icon value grammar: Material Icon Theme
 * defs (files/folders/anything), LobeHub brand svgs (AI/dev logos), emoji,
 * data: images, initials. Verbs: search · for-file · for-folder · get ·
 * grammar. Line-oriented output by default; `--json` everywhere.
 *
 * GRAMMAR SYNC — single source of truth, two homes: this grammar IS the
 * grammar the desktop resolves in desktop/src/lib/ui/Icon.svelte (and
 * materialIcon.ts resolves the mi: defs). Values an agent writes here render
 * in the desktop unchanged. Change the grammar in one place → change the
 * other (both files carry this note).
 *
 * Tri-modal like every JS-lane toolkit: runs under Node (argv via
 * process.argv) and inside the QuickJS wasm lane (#+ARG_MODE: stdin1 — the
 * registry folds argv into the first stdin line; Javy.IO does the io).
 * Data rides inline (src/index.js is generated): the wasm lane compiles one
 * file, no module resolution, no fs.
 */

const PACKS = globalThis.__ICONS_PACKS;
const M = PACKS.material;

const LOBE_BASE =
  "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons";
const MI_BASE = `https://cdn.jsdelivr.net/npm/material-icon-theme@${M.version}/icons`;

/**
 * Legacy stored values (lucide:<Name>) → Material Icon Theme defs.
 * KEEP IN SYNC with LEGACY_GLYPHS in desktop/src/lib/ui/Icon.svelte.
 */
const LEGACY_GLYPHS = {
  Kanban: "todo",
  SquareKanban: "todo",
  Notebook: "document",
  NotebookPen: "document",
  TrendUp: "table",
  TrendingUp: "table",
  ChartBar: "table",
  ChartColumn: "table",
  BookOpen: "readme",
  Briefcase: "lib",
  Rocket: "rocket",
  Wrench: "settings",
  Package: "zip",
};

const DEFS = new Set(M.defs);
const LOBE = new Set(PACKS.lobe.slugs);
const EMOJI = PACKS.emoji; // name → char

let EMOJI_BY_CHAR = null;
function emojiName(ch) {
  if (!EMOJI_BY_CHAR) {
    EMOJI_BY_CHAR = {};
    for (const [n, c] of Object.entries(EMOJI))
      if (!(c in EMOJI_BY_CHAR)) EMOJI_BY_CHAR[c] = n;
  }
  return EMOJI_BY_CHAR[ch] ?? null;
}

const miUrl = (def) => `${MI_BASE}/${def}.svg`;
const lobeUrl = (slug) => `${LOBE_BASE}/${slug}.svg`;

// ---------------------------------------------------------------------------
// Resolution — mirrors desktop/src/lib/ui/materialIcon.ts exactly.
// ---------------------------------------------------------------------------

/** A def only resolves if its svg ships in the set (urlFor() parity). */
const known = (def) => (def && DEFS.has(def) ? def : undefined);

/** mi:<def> for a file, by name (basename or full path) — fileIconUrl port. */
function forFile(name) {
  const base = name.split("/").pop()?.toLowerCase() ?? "";
  let def = known(M.fileNames[base]);
  let via = def ? `fileNames["${base}"]` : null;
  if (!def) {
    // Longest-suffix extension match — manifest keys include multi-dot
    // extensions like "d.ts", "test.tsx".
    const parts = base.split(".");
    for (let i = 1; i < parts.length && !def; i++) {
      const ext = parts.slice(i).join(".");
      def = known(M.fileExtensions[ext]);
      if (def) via = `fileExtensions["${ext}"]`;
    }
  }
  if (!def) {
    def = M.file;
    via = "default (file)";
  }
  return { def, via };
}

/** mi:<def> for a folder by name; `open` picks the expanded variant. */
function forFolder(name, open = false) {
  const key = name.trim().toLowerCase();
  const closed = M.folderNames[key];
  // folderNamesExpanded is derived: <closed>-open (verified by build-packs).
  const def = known(open ? (closed ? `${closed}-open` : undefined) : closed);
  if (def) return { def, via: `folderNames["${key}"]${open ? " (open)" : ""}` };
  return {
    def: open ? M.folderExpanded : M.folder,
    via: `default (${open ? "folder-open" : "folder"})`,
  };
}

// ---------------------------------------------------------------------------
// Unified search — exact > prefix > substring, across all three namespaces.
// ---------------------------------------------------------------------------

function rank(name, q) {
  return name === q ? 0 : name.startsWith(q) ? 1 : name.includes(q) ? 2 : -1;
}

function search(query, { limit = 30, kind = null } = {}) {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  const hits = [];
  const want = (k) => !kind || kind === k;

  if (want("material"))
    for (const def of M.defs) {
      const r = rank(def, q);
      if (r >= 0)
        hits.push({ rank: r, value: `mi:${def}`, kind: "material", name: def, url: miUrl(def) });
    }
  if (want("emoji"))
    for (const [name, ch] of Object.entries(EMOJI)) {
      const r = rank(name, q);
      if (r >= 0) hits.push({ rank: r, value: ch, kind: "emoji", name, url: null });
    }
  if (want("lobe"))
    for (const slug of PACKS.lobe.slugs) {
      const r = rank(slug, q);
      if (r >= 0)
        hits.push({ rank: r, value: `lobe:${slug}`, kind: "lobe", name: slug, url: lobeUrl(slug) });
    }

  hits.sort(
    (a, b) => a.rank - b.rank || a.name.localeCompare(b.name) || a.kind.localeCompare(b.kind),
  );
  return hits.slice(0, limit).map(({ rank: _r, ...h }) => h);
}

// ---------------------------------------------------------------------------
// get — resolve ANY grammar value to its source (Icon.svelte dispatch order).
// ---------------------------------------------------------------------------

function get(value) {
  if (value === "")
    return {
      value,
      kind: "initials",
      renders: "initials of the item's name (host-computed)",
    };
  if (value.startsWith("mi:")) {
    const def = value.slice(3);
    const ok = DEFS.has(def);
    return {
      value,
      kind: "material",
      def,
      known: ok,
      url: ok ? miUrl(def) : null,
      ...(ok ? {} : { renders: "initials (unresolvable prefixed value)" }),
    };
  }
  if (value.startsWith("lobe:")) {
    const slug = value.slice("lobe:".length);
    const ok = LOBE.has(slug);
    return {
      value,
      kind: "lobe",
      slug,
      known: ok,
      url: lobeUrl(slug),
      ...(ok ? {} : { renders: "initials if the svg 404s (slug not in the vendored list)" }),
    };
  }
  if (value.startsWith("lucide:")) {
    const def = LEGACY_GLYPHS[value.slice("lucide:".length)];
    return def
      ? { value, kind: "legacy-lucide", mapped: `mi:${def}`, def, known: true, url: miUrl(def) }
      : { value, kind: "legacy-lucide", known: false, renders: "initials (unmapped legacy value)" };
  }
  if (value.startsWith("data:image/")) return { value: "data:image/…", kind: "image" };
  const name = emojiName(value);
  return { value, kind: "emoji", ...(name ? { name } : {}), known: name != null };
}

// ---------------------------------------------------------------------------
// grammar — the value grammar, printable (the sync contract, spelled out).
// ---------------------------------------------------------------------------

const GRAMMAR = `icon value grammar — one string resolves everywhere
(single source of truth with desktop/src/lib/ui/Icon.svelte — change one, change the other)

  ""                  initials of the item's name (the empty default)
  mi:<def>            Material Icon Theme svg by definition name (mi:rust, mi:folder-src)
                      → ${MI_BASE}/<def>.svg
  lobe:<slug>         LobeHub brand svg (AI/LLM/dev-tool logos; lobe:openai)
                      → ${LOBE_BASE}/<slug>.svg
  lucide:<Name>       LEGACY — old stored values; maps to the closest mi: def, never render raw
  data:image/…        inline image (data URL), rendered as <img>
  <anything else>     emoji / glyph text, rendered as-is (🚀)

Unresolvable mi:/lobe:/lucide: values fall back to initials — never raw text.
Find values: icons search <query> · icons for-file <name> · icons for-folder <name> [--open]
Inspect one: icons get <value> [--json]`;

// ---------------------------------------------------------------------------
// CLI plumbing — argv in, lines (or --json) out, tri-modal io.
// ---------------------------------------------------------------------------

const HELP = `icons — universal icon library (material defs · lobe brand svgs · emoji)

usage:
  icons search <query> [--kind material|emoji|lobe] [--limit N] [--json]
  icons for-file <filename> [--json]      file → mi:<def> (fileNames > extensions > default)
  icons for-folder <name> [--open] [--json]
  icons get <value> [--json]              resolve any grammar value → kind/source/url
  icons grammar                           print the icon value grammar

output (line mode): <value>\\t<kind>\\t<name>\\t<url>
values render in any workbook/desktop surface via the shared grammar (icons grammar).`;

function parseArgs(argv) {
  const pos = [];
  const flags = { json: false, open: false, limit: 30, kind: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--json") flags.json = true;
    else if (a === "--open") flags.open = true;
    else if (a === "--limit") flags.limit = Math.max(1, parseInt(argv[++i], 10) || 30);
    else if (a === "--kind") flags.kind = argv[++i] ?? null;
    else pos.push(a);
  }
  return { pos, flags };
}

const line = (h) => [h.value, h.kind, h.name ?? h.def ?? "", h.url ?? ""].join("\t");

function main(argv) {
  const { pos, flags } = parseArgs(argv);
  const [verb, ...rest] = pos;
  const arg = rest.join(" "); // filenames/queries with spaces survive stdin1 folding
  const J = (x) => JSON.stringify(x, null, 2);

  switch (verb) {
    case "search": {
      if (!arg) return { out: "usage: icons search <query>", code: 1 };
      const hits = search(arg, { limit: flags.limit, kind: flags.kind });
      if (flags.json) return { out: J(hits), code: 0 };
      if (hits.length === 0) return { out: `(no icons match ${JSON.stringify(arg)})`, code: 1 };
      return { out: hits.map(line).join("\n"), code: 0 };
    }
    case "for-file": {
      if (!arg) return { out: "usage: icons for-file <filename>", code: 1 };
      const { def, via } = forFile(arg);
      const hit = { value: `mi:${def}`, kind: "material", def, via, url: miUrl(def) };
      return { out: flags.json ? J(hit) : `${hit.value}\t${via}\t${hit.url}`, code: 0 };
    }
    case "for-folder": {
      if (!arg) return { out: "usage: icons for-folder <name> [--open]", code: 1 };
      const { def, via } = forFolder(arg, flags.open);
      const hit = { value: `mi:${def}`, kind: "material", def, via, url: miUrl(def) };
      return { out: flags.json ? J(hit) : `${hit.value}\t${via}\t${hit.url}`, code: 0 };
    }
    case "get": {
      const value = rest.length > 0 ? arg : "";
      const hit = get(value);
      if (flags.json) return { out: J(hit), code: hit.known === false ? 1 : 0 };
      const bits = [hit.value, hit.kind];
      if (hit.mapped) bits.push(`→ ${hit.mapped}`);
      if (hit.name) bits.push(hit.name);
      if (hit.known === false) bits.push("(unknown — renders as initials)");
      if (hit.renders && hit.known !== false) bits.push(`renders: ${hit.renders}`);
      if (hit.url) bits.push(hit.url);
      return { out: bits.join("\t"), code: hit.known === false ? 1 : 0 };
    }
    case "grammar":
      return { out: GRAMMAR, code: 0 };
    case undefined:
    case "help":
    case "--help":
      return { out: HELP, code: 0 };
    default:
      return { out: `unknown verb: ${verb}\n\n${HELP}`, code: 1 };
  }
}

// io seam — Node vs the QuickJS wasm lane (stdin1: argv rides the first stdin line).
if (typeof process !== "undefined" && process.argv) {
  const { out, code } = main(process.argv.slice(2));
  console.log(out);
  process.exitCode = code;
} else {
  const chunks = [];
  const buf = new Uint8Array(65536);
  let n;
  while ((n = Javy.IO.readSync(0, buf)) > 0) chunks.push(buf.slice(0, n));
  let total = 0;
  for (const c of chunks) total += c.length;
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    all.set(c, off);
    off += c.length;
  }
  const first = new TextDecoder().decode(all).split("\n", 1)[0].trim();
  const argv = first === "" ? [] : first.split(/\s+/);
  const { out } = main(argv);
  Javy.IO.writeSync(1, new TextEncoder().encode(out + "\n"));
}
