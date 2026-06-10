/*!
 * open-avatars — deterministic, seed-based SVG avatars (zero dependencies)
 *
 * Pure string → string. Runs in a browser <script> tag (window.OpenAvatars),
 * as an ES module (export { avatar }), in Node, and in the runtime's QuickJS
 * wasm JS lane. No DOM, no Node APIs, no fetch. Bad input never throws.
 *
 * The avatar is composed from a PACK BUNDLE — a pure JSON object produced by
 * scripts/bundle-pack.mjs ({ ...pack.json, atoms: { <cat>: { <name>: inner } } }).
 * avatar() is therefore a total function of (bundle, seed, opts): the same seed
 * always yields byte-identical SVG, forever (the DiceBear contract).
 *
 * API:
 *   avatar(pack, seed, opts) -> string     // a complete <svg> document string
 *     pack  : a pack bundle object (from pack.bundle.json), or null to use a
 *             previously registered() default.
 *     seed  : any string. Hashed (FNV-1a) to pick one atom per category.
 *     opts  : {
 *       crop:        'circle' | 'bust' | 'full'   (default 'circle')
 *       categories:  string[] subset to draw      (default: crop-appropriate)
 *       background:  CSS color for a backplate     (default: none/transparent)
 *       size:        px for width/height attrs     (default: none → scales to box)
 *       title:       <title> text for a11y         (default: the seed)
 *     }
 *   pick(pack, seed) -> { <cat>: <name> }   // which atoms a seed selects
 *   register(pack) -> void                   // set a default bundle for avatar(null,…)
 *
 * Monochrome by law: the atoms ship black-on-white. avatar() never recolors
 * them. To theme, set opts.background (a backplate behind the figure) or style
 * the host <svg>/wrapper from CSS — the ink stays black, the fills stay white.
 */

// ---------- deterministic hashing ----------
//
// FNV-1a (32-bit). Stable across engines, no float math, no platform deps.
// A per-category sub-seed ("seed#category") keeps category choices independent
// yet fully determined by the root seed.

function fnv1a(str) {
  var h = 0x811c9dc5;
  for (var i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    // h *= 16777619, kept in 32-bit unsigned via Math.imul
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

// ---------- atom selection ----------

// Sorted atom names for a category — deterministic ordering independent of
// however JSON enumerated the keys.
function namesOf(bundle, cat) {
  var obj = bundle.atoms && bundle.atoms[cat];
  if (!obj) return [];
  return Object.keys(obj).sort();
}

// Choose one atom name for a category from a seed.
function chooseName(bundle, cat, seed) {
  var names = namesOf(bundle, cat);
  if (names.length === 0) return null;
  var idx = fnv1a(seed + "#" + cat) % names.length;
  return names[idx];
}

/**
 * pick(pack, seed) -> { <cat>: <name> }
 * The pure selection step: which atom each category resolves to for this seed.
 */
function pick(pack, seed) {
  var bundle = resolve(pack);
  var out = {};
  var cats = Object.keys(bundle.categories || {});
  for (var i = 0; i < cats.length; i++) {
    out[cats[i]] = chooseName(bundle, cats[i], String(seed));
  }
  return out;
}

// ---------- composition ----------

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Categories to draw by default, by crop. A face avatar (circle) omits the
// body; bust/full include it. Any explicit opts.categories overrides this.
function defaultCats(bundle, crop) {
  var all = Object.keys(bundle.categories || {});
  if (crop === "bust" || crop === "full") return all;
  // circle (face) avatar: everything except the body.
  return all.filter(function (c) {
    return c !== "body";
  });
}

// The drawable layers in z-order for the chosen atoms + categories.
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

// Resolve a crop spec into { viewBox:[x,y,w,h], clip?:{cx,cy,r} }.
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
  // circle: a square viewBox around the crop disc, plus a clip.
  var c = crops.circle || { cx: canvas[0] / 2, cy: canvas[1] / 2, r: canvas[0] / 2 };
  return {
    viewBox: [c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2],
    clip: { cx: c.cx, cy: c.cy, r: c.r },
  };
}

/**
 * avatar(pack, seed, opts) -> SVG string
 */
function avatar(pack, seed, opts) {
  opts = opts || {};
  var bundle = resolve(pack);
  seed = String(seed == null ? "" : seed);

  var crop = opts.crop || "circle";
  var box = cropBox(bundle, crop);
  var vb = box.viewBox;

  var cats = opts.categories || defaultCats(bundle, crop);
  var chosen = {};
  for (var i = 0; i < cats.length; i++) {
    chosen[cats[i]] = chooseName(bundle, cats[i], seed);
  }
  var ls = layers(bundle, chosen, cats);

  // A stable, seed-derived id so two avatars on one page never collide.
  var uid = "oa" + fnv1a(seed + "|" + crop).toString(36);

  var body = "";
  for (var j = 0; j < ls.length; j++) {
    var l = ls[j];
    // Skip empties ("None" atoms) — emit nothing rather than a hollow <g>.
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

  var sizeAttr = "";
  if (opts.size) {
    sizeAttr = ' width="' + opts.size + '" height="' + opts.size + '"';
  }

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

// ---------- default-bundle registry ----------

var _default = null;
function register(pack) {
  _default = pack;
}
function resolve(pack) {
  var b = pack || _default;
  if (!b || typeof b !== "object" || !b.categories) {
    // Degrade, never throw: an empty 1×1 transparent canvas.
    return { name: "(none)", canvas: [1, 1], categories: {}, crops: {}, atoms: {} };
  }
  return b;
}

// ---------- exports ----------

var OpenAvatars = { avatar: avatar, pick: pick, register: register, version: "0.1.0" };

// Browser global
if (typeof window !== "undefined") {
  window.OpenAvatars = OpenAvatars;
}
// CommonJS / QuickJS-with-module shim tolerance
if (typeof module !== "undefined" && module.exports) {
  module.exports = OpenAvatars;
}

export { avatar, pick, register };
export default OpenAvatars;
