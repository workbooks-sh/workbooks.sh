/*!
 * glyphs — one API resolves any visual mark to an SVG/img.
 *
 * A unified, zero-dependency mark resolver. `glyph(ref, opts)` takes a string
 * ref `"<kind>:<id>"` and returns an SVG string (or an <img> for social/raster
 * marks). Curated-local-first, with a CDN fallback for the long tail.
 *
 *   brand:<name>    full-color brand logo  (curated → svgl → lobehub → simple-icons)
 *   icon:<name>     tech/UI icon           (curated → simple-icons → lobehub)
 *   avatar:<pack>/<seed>   delegate to open-avatars avatar(pack, seed, opts)
 *   social:<provider>/<user>   unavatar → <img src="https://unavatar.io/…">
 *
 * Two entry points — the sync/async split is the whole design:
 *
 *   glyph(ref, opts)       SYNC. Curated-local only. Returns null if a brand/icon
 *                          isn't in the curated packs (no network). avatar/social
 *                          always resolve sync (avatar is local+pure; social is
 *                          just an <img> tag — the browser fetches the pixels).
 *   glyphAsync(ref, opts)  ASYNC. Same, but brand/icon fall through to the CDN
 *                          when not curated (returns a Promise<string|null>).
 *
 * A miss — no curated entry and (async) a CDN 404 — returns null. The caller
 * renders nothing: honest, never a broken-image box.
 *
 * Runs in a browser <script> (window.Glyphs), as an ES module, in Node, and in
 * the runtime's QuickJS wasm JS lane. The CDN path needs a global `fetch`; where
 * fetch is absent (some wasm/Node contexts) the curated-only sync path still
 * works and glyphAsync degrades to the curated result (or null).
 *
 * Packs (plain JSON, inlined by the consumer or fetched) wire in via configure():
 *   configure({ brands, icons, svglIndex, avatarPacks, avatarFn })
 * The shipped specimen + Node loader read them from ../packs/*.json.
 */

// ---------- pack registry ----------
//
// Curated maps + the svgl name→route index + avatar delegation are injected by
// the host (so the core stays pure data-in / string-out, no fs, no import of
// JSON). Defaults are empty — configure() before calling for brand/icon hits.

var REG = {
  brands: {}, // name -> inlined full-color SVG string
  icons: {}, // name -> inlined currentColor SVG string
  logos: {}, // toolkit id -> inlined full-color logo SVG (vendored from Nango template-logos)
  svglIndex: {}, // name(lowercase) -> svgl route url (long-tail brands)
  avatarPacks: {}, // pack name -> avatar bundle object
  avatarFn: null, // open-avatars avatar(pack, seed, opts)
};

function configure(cfg) {
  cfg = cfg || {};
  if (cfg.brands) REG.brands = cfg.brands;
  if (cfg.icons) REG.icons = cfg.icons;
  if (cfg.logos) REG.logos = cfg.logos;
  if (cfg.svglIndex) REG.svglIndex = cfg.svglIndex;
  if (cfg.avatarPacks) REG.avatarPacks = cfg.avatarPacks;
  if (cfg.avatarFn) REG.avatarFn = cfg.avatarFn;
  return REG;
}

// ---------- helpers ----------

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

var SIMPLE_BASE = "https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/";
var LOBE_BASE =
  "https://cdn.jsdelivr.net/gh/lobehub/lobe-icons@master/packages/static-svg/icons/";
var UNAVATAR_BASE = "https://unavatar.io/";

// simple-icons / lobehub slug: lowercase, strip spaces & dots.
function slugify(name) {
  return String(name).toLowerCase().replace(/[\s.]+/g, "");
}

function looksLikeSvg(s) {
  return typeof s === "string" && /^<svg[\s>]/.test(s.trim());
}

function hasFetch() {
  return typeof fetch === "function";
}

// Parse `"<kind>:<id>"`. The id keeps everything after the FIRST colon, so
// avatar:open-peeps/wren and social:github/octocat split cleanly; an id may
// itself contain `/` (pack/seed, provider/user).
function parseRef(ref) {
  if (typeof ref !== "string") return null;
  var i = ref.indexOf(":");
  if (i < 0) return null;
  var kind = ref.slice(0, i).trim().toLowerCase();
  var id = ref.slice(i + 1).trim();
  if (!kind || !id) return null;
  return { kind: kind, id: id };
}

// ---------- SVG post-processing (size / color / title / class / mono) ----------
//
// We mutate only the root <svg ...> tag's attributes: set width/height (size),
// inject a title + aria, add a class, and recolor. simple-icons/lobehub marks
// are single-path currentColor → `color` just sets the CSS color on the root.
// svgl full-color marks are left as-is unless `forceMono` (mono brand context),
// which applies a grayscale filter via the class hook.

function applyOpts(svg, opts, kind) {
  opts = opts || {};
  if (!looksLikeSvg(svg)) return svg;

  var size = opts.size != null ? opts.size : "1em";
  var sizeVal = typeof size === "number" ? size + "px" : String(size);

  // pull the opening <svg ...> tag
  var m = svg.match(/^\s*<svg\b([^>]*)>/i);
  if (!m) return svg;
  var attrs = m[1];
  var rest = svg.slice(m[0].length);

  // Capture the intrinsic size BEFORE we strip width/height. If the mark has no viewBox (common in the Nango
  // logos), its path coords live in that intrinsic space — without a viewBox the mark renders at 1:1 and
  // overflows the sized box. Synthesise `viewBox="0 0 W H"` so it scales to fit.
  var hasViewBox = /\sviewBox=/i.test(attrs);
  var wm = attrs.match(/\swidth="([0-9.]+)[^"]*"/i);
  var hm = attrs.match(/\sheight="([0-9.]+)[^"]*"/i);

  // strip any existing width/height/class/style we will replace, keep the rest
  // (notably viewBox, xmlns, fill-rule, paths' colors).
  attrs = attrs
    .replace(/\swidth="[^"]*"/i, "")
    .replace(/\sheight="[^"]*"/i, "")
    .replace(/\sclass="[^"]*"/i, "");

  if (!hasViewBox && wm && hm) attrs += ' viewBox="0 0 ' + wm[1] + " " + hm[1] + '"';

  // class list
  var cls = ["glyph", "glyph--" + kind];
  // monochrome currentColor marks (icon, simple-icons/lobehub brands) inherit
  // color from CSS; svgl full-color brands force grayscale only when asked.
  if (opts.mono) cls.push("glyph--mono");
  if (opts.class) cls.push(opts.class);

  // style: size + (for currentColor marks) color.
  var style = "width:" + sizeVal + ";height:" + sizeVal + ";";
  // ensure the svg scales to the box even if it had a fixed width attr.
  if (opts.color) style += "color:" + opts.color + ";";

  var titleText = opts.title != null ? opts.title : "";
  var titleA11y = titleText
    ? ' role="img" aria-label="' + esc(titleText) + '"'
    : "";

  var head =
    "<svg" +
    attrs +
    ' class="' +
    cls.join(" ") +
    '"' +
    ' style="' +
    style +
    '"' +
    titleA11y +
    ">";

  // replace/insert a <title> if asked (drop any existing one first).
  rest = rest.replace(/<title>[\s\S]*?<\/title>/i, "");
  if (titleText) head += "<title>" + esc(titleText) + "</title>";

  return head + rest;
}

// ---------- brand / icon: curated lookup ----------

function curatedBrand(name) {
  var key = String(name).toLowerCase();
  var svg = REG.brands[key];
  return looksLikeSvg(svg) ? svg : null;
}

function curatedIcon(name) {
  var key = String(name).toLowerCase();
  var svg = REG.icons[key];
  return looksLikeSvg(svg) ? svg : null;
}

// ---------- avatar (sync, delegated to open-avatars) ----------
//
// avatar:<pack>/<seed>  → avatar(packBundle, seed, opts). Determinism preserved:
// the seed flows straight to open-avatars' FNV pick. Returns null if no avatar
// engine / pack is configured (honest miss).

function resolveAvatar(id, opts) {
  var slash = id.indexOf("/");
  var packName = slash < 0 ? id : id.slice(0, slash);
  var seed = slash < 0 ? "" : id.slice(slash + 1);
  var bundle = REG.avatarPacks[packName];
  if (!bundle || typeof REG.avatarFn !== "function") return null;
  var out = REG.avatarFn(bundle, seed, opts || {});
  return typeof out === "string" && out ? out : null;
}

// ---------- social (sync, an <img> the browser fetches) ----------
//
// social:<provider>/<user> → <img src="https://unavatar.io/<provider>/<user>">.
// This is the ONE kind that fetches a real (raster) avatar; it's a plain <img>,
// so resolution is sync — the network happens in the browser when the tag loads.

function resolveSocial(id, opts) {
  opts = opts || {};
  // id is "<provider>/<user>"; pass through verbatim (unavatar takes both forms,
  // e.g. github/octocat, twitter/x, or a bare email/domain).
  var src = UNAVATAR_BASE + id;
  var size = opts.size != null ? opts.size : "1em";
  var sizeVal = typeof size === "number" ? size + "px" : String(size);
  var cls = ["glyph", "glyph--social"];
  if (opts.mono) cls.push("glyph--mono");
  if (opts.class) cls.push(opts.class);
  var alt = opts.title != null ? opts.title : id;
  return (
    '<img src="' +
    esc(src) +
    '" alt="' +
    esc(alt) +
    '" class="' +
    cls.join(" ") +
    '" style="width:' +
    sizeVal +
    ";height:" +
    sizeVal +
    ';object-fit:cover" loading="lazy">'
  );
}

// ---------- sync core ----------
//
// glyph(ref, opts) — curated-only for brand/icon (null if not local). avatar &
// social always resolve here (no CDN round-trip needed for them).

function glyph(ref, opts) {
  var p = parseRef(ref);
  if (!p) return null;

  if (p.kind === "logo") {
    var lg = REG.logos[p.id];
    return looksLikeSvg(lg) ? applyOpts(lg, opts, "logo") : null;
  }
  if (p.kind === "brand") {
    var b = curatedBrand(p.id);
    return b ? applyOpts(b, withMono(opts, p.id), "brand") : null;
  }
  if (p.kind === "icon") {
    var ic = curatedIcon(p.id);
    return ic ? applyOpts(ic, opts, "icon") : null;
  }
  if (p.kind === "avatar") return resolveAvatar(p.id, opts);
  if (p.kind === "social") return resolveSocial(p.id, opts);
  return null;
}

// `mono: true` on a brand forces grayscale on the full-color mark.
function withMono(opts, name) {
  return opts || {};
}

// ---------- async resolution (CDN long-tail for brand/icon) ----------

async function fetchSvg(url) {
  if (!hasFetch()) return null;
  try {
    var r = await fetch(url, { redirect: "follow" });
    if (!r.ok) return null;
    var t = (await r.text()).trim();
    return looksLikeSvg(t) ? t : null;
  } catch (e) {
    return null;
  }
}

// brand resolve order: curated → svgl (via index route) → lobehub → simple-icons.
async function resolveBrandAsync(name) {
  var local = curatedBrand(name);
  if (local) return local;
  if (!hasFetch()) return null;

  var key = String(name).toLowerCase();
  // 1. svgl (full color) via the bundled name→route index — one fetch.
  var route = REG.svglIndex[key];
  if (route) {
    var s = await fetchSvg(route);
    if (s) return s;
  }
  // 2. lobehub (AI/LLM, currentColor)
  var lobe = await fetchSvg(LOBE_BASE + slugify(name) + ".svg");
  if (lobe) return lobe;
  // 3. simple-icons (currentColor monochrome)
  var si = await fetchSvg(SIMPLE_BASE + slugify(name) + ".svg");
  if (si) return si;
  return null;
}

// icon resolve order: curated → simple-icons → lobehub.
async function resolveIconAsync(name) {
  var local = curatedIcon(name);
  if (local) return local;
  if (!hasFetch()) return null;
  var si = await fetchSvg(SIMPLE_BASE + slugify(name) + ".svg");
  if (si) return si;
  var lobe = await fetchSvg(LOBE_BASE + slugify(name) + ".svg");
  if (lobe) return lobe;
  return null;
}

async function glyphAsync(ref, opts) {
  var p = parseRef(ref);
  if (!p) return null;

  if (p.kind === "brand") {
    var b = await resolveBrandAsync(p.id);
    return b ? applyOpts(b, withMono(opts, p.id), "brand") : null;
  }
  if (p.kind === "icon") {
    var ic = await resolveIconAsync(p.id);
    return ic ? applyOpts(ic, opts, "icon") : null;
  }
  // avatar + social are already sync — no network round-trip to await.
  if (p.kind === "avatar") return resolveAvatar(p.id, opts);
  if (p.kind === "social") return resolveSocial(p.id, opts);
  return null;
}

// ---------- exports ----------

var Glyphs = {
  glyph: glyph,
  glyphAsync: glyphAsync,
  configure: configure,
  parseRef: parseRef,
  version: "0.1.0",
};

if (typeof window !== "undefined") {
  window.Glyphs = Glyphs;
}
if (typeof module !== "undefined" && module.exports) {
  module.exports = Glyphs;
}

export { glyph, glyphAsync, configure, parseRef };
export default Glyphs;
