/*!
 * open-avatars — deterministic, seed-based avatars (zero dependencies)
 *
 * "Many art styles, one DiceBear-like API." A single avatar() routes by a
 * pack's declared `type`:
 *
 *   - "assembled"  — compose a figure from atoms + offsets (the open-peeps path).
 *   - "gallery"    — pick ONE complete avatar by seed from a list.
 *                      kind:"svg"    → a whole inline SVG, framed to a square.
 *                      kind:"raster" → an <img> whose src is opts.base + path.
 *   - "procedural" — call a pure generate(seed, opts) → svgString the pack ships.
 *
 * Pure string → string. Runs in a browser <script> tag (window.OpenAvatars),
 * as an ES module (export { avatar }), in Node, and in the runtime's QuickJS
 * wasm JS lane. No DOM, no Node APIs, no fetch. Bad input never throws.
 *
 * Determinism is sacred everywhere: the same seed yields byte-identical output,
 * forever (the DiceBear contract). Selection is FNV-1a over a SORTED id list, so
 * it is independent of however JSON enumerated keys.
 *
 * API:
 *   avatar(pack, seed, opts) -> string
 *     pack : a pack bundle object (assembled/gallery) or a procedural pack with
 *            a `generate` function attached; or null to use a register()'d default.
 *     seed : any string. Hashed (FNV-1a) for selection.
 *     opts : assembled — { crop, categories, background, size, title }
 *            gallery   — { base, size, title, background }  (base for raster src)
 *            procedural— passed straight through to the pack's generate()
 *   pick(pack, seed)     -> assembled: {<cat>:<name>} · gallery: chosen id
 *   register(pack)       -> set a default for avatar(null, …)
 */

// ---------- deterministic hashing ----------
//
// FNV-1a (32-bit). Stable across engines, no float math, no platform deps.

function fnv1a(str) {
  var h = 0x811c9dc5;
  for (var i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// =====================================================================
// ASSEMBLED — compose atoms by category (open-peeps). Unchanged behavior.
// =====================================================================

function namesOf(bundle, cat) {
  var obj = bundle.atoms && bundle.atoms[cat];
  if (!obj) return [];
  return Object.keys(obj).sort();
}

function chooseName(bundle, cat, seed) {
  var names = namesOf(bundle, cat);
  if (names.length === 0) return null;
  var idx = fnv1a(seed + "#" + cat) % names.length;
  return names[idx];
}

function pickAssembled(bundle, seed) {
  var out = {};
  var cats = Object.keys(bundle.categories || {});
  for (var i = 0; i < cats.length; i++) {
    out[cats[i]] = chooseName(bundle, cats[i], String(seed));
  }
  return out;
}

function defaultCats(bundle, crop) {
  var all = Object.keys(bundle.categories || {});
  if (crop === "bust" || crop === "full") return all;
  return all.filter(function (c) {
    return c !== "body";
  });
}

function layers(bundle, chosen, cats) {
  var defs = bundle.categories || {};
  var out = [];
  for (var i = 0; i < cats.length; i++) {
    var cat = cats[i];
    var def = defs[cat];
    if (!def) continue;
    var name = chosen[cat];
    if (name == null) continue;
    var inner = bundle.atoms && bundle.atoms[cat] && bundle.atoms[cat][name];
    if (inner == null) inner = "";
    out.push({
      z: typeof def.z === "number" ? def.z : i,
      ox: def.offset[0],
      oy: def.offset[1],
      inner: inner,
      cat: cat,
      name: name,
    });
  }
  out.sort(function (a, b) {
    return a.z - b.z;
  });
  return out;
}

function cropBox(bundle, crop) {
  var crops = bundle.crops || {};
  var canvas = bundle.canvas || [1136, 1533];
  if (crop === "full") {
    var f = (crops.full && crops.full.viewBox) || [0, 0, canvas[0], canvas[1]];
    return { viewBox: f };
  }
  if (crop === "bust") {
    var b = (crops.bust && crops.bust.viewBox) || [0, 0, canvas[0], canvas[1]];
    return { viewBox: b };
  }
  var c = crops.circle || { cx: canvas[0] / 2, cy: canvas[1] / 2, r: canvas[0] / 2 };
  return {
    viewBox: [c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2],
    clip: { cx: c.cx, cy: c.cy, r: c.r },
  };
}

function avatarAssembled(bundle, seed, opts) {
  var crop = opts.crop || "circle";
  var box = cropBox(bundle, crop);
  var vb = box.viewBox;

  var cats = opts.categories || defaultCats(bundle, crop);
  var chosen = {};
  for (var i = 0; i < cats.length; i++) {
    chosen[cats[i]] = chooseName(bundle, cats[i], seed);
  }
  var ls = layers(bundle, chosen, cats);

  var uid = "oa" + fnv1a(seed + "|" + crop).toString(36);

  var body = "";
  for (var j = 0; j < ls.length; j++) {
    var l = ls[j];
    if (!l.inner) continue;
    body +=
      '<g transform="translate(' +
      l.ox +
      "," +
      l.oy +
      ')" data-cat="' +
      esc(l.cat) +
      '" data-atom="' +
      esc(l.name) +
      '">' +
      l.inner +
      "</g>";
  }

  var defsParts = [];
  var groupOpen = "<g";
  if (box.clip) {
    var clipId = uid + "c";
    defsParts.push(
      '<clipPath id="' +
        clipId +
        '"><circle cx="' +
        box.clip.cx +
        '" cy="' +
        box.clip.cy +
        '" r="' +
        box.clip.r +
        '"/></clipPath>'
    );
    groupOpen += ' clip-path="url(#' + clipId + ')"';
  }
  groupOpen += ">";

  var bg = "";
  if (opts.background) {
    if (box.clip) {
      bg =
        '<circle cx="' +
        box.clip.cx +
        '" cy="' +
        box.clip.cy +
        '" r="' +
        box.clip.r +
        '" fill="' +
        esc(opts.background) +
        '"/>';
    } else {
      bg =
        '<rect x="' +
        vb[0] +
        '" y="' +
        vb[1] +
        '" width="' +
        vb[2] +
        '" height="' +
        vb[3] +
        '" fill="' +
        esc(opts.background) +
        '"/>';
    }
  }

  var sizeAttr = opts.size ? ' width="' + opts.size + '" height="' + opts.size + '"' : "";
  var titleText = opts.title != null ? opts.title : seed;

  return (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="' +
    vb.join(" ") +
    '"' +
    sizeAttr +
    ' role="img" aria-label="' +
    esc(titleText) +
    '">' +
    "<title>" +
    esc(titleText) +
    "</title>" +
    (defsParts.length ? "<defs>" + defsParts.join("") + "</defs>" : "") +
    bg +
    groupOpen +
    body +
    "</g>" +
    "</svg>"
  );
}

// =====================================================================
// GALLERY — pick one complete avatar from a sorted id list by seed.
// =====================================================================

// A gallery bundle carries an `items` map or an `ids` list.
//   kind:"svg"    items = { <id>: "<inner svg string>" }, plus viewBox [w,h]
//   kind:"raster" ids   = [ <id>, … ], plus `path` template "webp/<id>.webp"
function galleryIds(bundle) {
  if (bundle.ids && bundle.ids.length) return bundle.ids.slice().sort();
  if (bundle.items) return Object.keys(bundle.items).sort();
  return [];
}

function pickGallery(bundle, seed) {
  var ids = galleryIds(bundle);
  if (!ids.length) return null;
  return ids[fnv1a(String(seed)) % ids.length];
}

function avatarGallerySvg(bundle, seed, opts) {
  var id = pickGallery(bundle, seed);
  var titleText = opts.title != null ? opts.title : seed;
  var sizeAttr = opts.size ? ' width="' + opts.size + '" height="' + opts.size + '"' : "";

  // Frame the chosen figure to a square viewBox. Gallery SVGs may export at a
  // non-square viewBox (e.g. 1080×1099); we normalize to a centered square so
  // every style sits in the same box. Native art/colors are kept verbatim.
  var inner = (id != null && bundle.items && bundle.items[id]) || "";
  var vbw = (bundle.viewBox && bundle.viewBox[0]) || 1080;
  var vbh = (bundle.viewBox && bundle.viewBox[1]) || 1080;
  var side = Math.max(vbw, vbh);
  var ox = (side - vbw) / 2;
  var oy = (side - vbh) / 2;
  var vb = [0, 0, side, side];

  var bg = "";
  if (opts.background) {
    bg =
      '<rect x="0" y="0" width="' +
      side +
      '" height="' +
      side +
      '" fill="' +
      esc(opts.background) +
      '"/>';
  }

  var content =
    ox || oy
      ? '<g transform="translate(' + ox + "," + oy + ')">' + inner + "</g>"
      : inner;

  return (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="' +
    vb.join(" ") +
    '"' +
    sizeAttr +
    ' role="img" aria-label="' +
    esc(titleText) +
    '" data-id="' +
    esc(id == null ? "" : id) +
    '">' +
    "<title>" +
    esc(titleText) +
    "</title>" +
    bg +
    content +
    "</svg>"
  );
}

function avatarGalleryRaster(bundle, seed, opts) {
  var id = pickGallery(bundle, seed);
  var titleText = opts.title != null ? opts.title : seed;
  // path template: "webp/<id>.webp" → substitute the chosen id.
  var tmpl = bundle.path || "<id>";
  var rel = String(tmpl).replace(/<id>/g, id == null ? "" : String(id));
  // base: where the consumer hosts the raster assets. Defaults to the pack's
  // own base if the bundle records one; otherwise the path is used as-is.
  var base = opts.base != null ? opts.base : bundle.base != null ? bundle.base : "";
  var src = base + rel;
  var sizeAttr = opts.size ? ' width="' + opts.size + '" height="' + opts.size + '"' : "";
  return (
    '<img src="' +
    esc(src) +
    '" alt="' +
    esc(titleText) +
    '"' +
    sizeAttr +
    ' data-id="' +
    esc(id == null ? "" : id) +
    '">'
  );
}

// =====================================================================
// PROCEDURAL — call the pack's pure generate(seed, opts) → svgString.
// =====================================================================

function avatarProcedural(pack, seed, opts) {
  if (typeof pack.generate !== "function") {
    return degradedSvg();
  }
  var out;
  try {
    out = pack.generate(seed, opts || {});
  } catch (e) {
    return degradedSvg();
  }
  return typeof out === "string" && out ? out : degradedSvg();
}

// =====================================================================
// DISPATCH
// =====================================================================

function degradedSvg() {
  return (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" role="img" aria-label="">' +
    "<title></title></svg>"
  );
}

function typeOf(pack) {
  if (!pack || typeof pack !== "object") return null;
  if (pack.type) return pack.type;
  // Back-compat: a bundle with `categories` is an assembled pack.
  if (pack.categories) return "assembled";
  return null;
}

/**
 * avatar(pack, seed, opts) -> string  (SVG, or <img> for raster galleries)
 */
function avatar(pack, seed, opts) {
  opts = opts || {};
  var p = pack || _default;
  seed = String(seed == null ? "" : seed);
  var t = typeOf(p);

  if (t === "assembled") return avatarAssembled(resolve(p), seed, opts);
  if (t === "procedural") return avatarProcedural(p, seed, opts);
  if (t === "gallery") {
    return p.kind === "raster"
      ? avatarGalleryRaster(p, seed, opts)
      : avatarGallerySvg(p, seed, opts);
  }
  return degradedSvg();
}

/**
 * pick(pack, seed) — assembled: {<cat>:<name>}; gallery: chosen id; else null.
 */
function pick(pack, seed) {
  var p = pack || _default;
  var t = typeOf(p);
  if (t === "assembled") return pickAssembled(resolve(p), seed);
  if (t === "gallery") return pickGallery(p, seed);
  return null;
}

// ---------- default-bundle registry ----------

var _default = null;
function register(pack) {
  _default = pack;
}
function resolve(pack) {
  var b = pack || _default;
  if (!b || typeof b !== "object" || !b.categories) {
    return { name: "(none)", canvas: [1, 1], categories: {}, crops: {}, atoms: {} };
  }
  return b;
}

// ---------- exports ----------

var OpenAvatars = { avatar: avatar, pick: pick, register: register, version: "0.2.0" };

if (typeof window !== "undefined") {
  window.OpenAvatars = OpenAvatars;
}
if (typeof module !== "undefined" && module.exports) {
  module.exports = OpenAvatars;
}

export { avatar, pick, register };
export default OpenAvatars;
