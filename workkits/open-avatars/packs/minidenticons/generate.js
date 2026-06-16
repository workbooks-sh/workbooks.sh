// minidenticons — 5×5 mirrored, seed-hued pixel identicon.
// Ported faithfully from https://github.com/laurentpayot/minidenticons (MIT).
//
// A pure, zero-dep generate(seed, opts) -> SVG string. Same seed → identical SVG.
// Native output is a single seed-derived hue; pass opts.monochrome to force B&W.

// 9 distinct colors only (also a sweet spot for collisions) — verbatim constants.
var COLORS_NB = 9;
var DEFAULT_SATURATION = 95;
var DEFAULT_LIGHTNESS = 45;
var MAGIC_NUMBER = 5;

// minidenticons' own simpleHash (NOT FNV) — keep it exact for byte-parity with
// the upstream library: same username → same identicon as the original.
function simpleHash(str) {
  return (
    str.split("").reduce(function (hash, char) {
      return (hash ^ char.charCodeAt(0)) * -MAGIC_NUMBER;
    }, MAGIC_NUMBER) >>> 2
  );
}

export function generate(seed, opts) {
  seed = seed == null ? "" : String(seed);
  opts = opts || {};
  var saturation = opts.saturation != null ? opts.saturation : DEFAULT_SATURATION;
  var lightness = opts.lightness != null ? opts.lightness : DEFAULT_LIGHTNESS;

  var hash = simpleHash(seed);
  var hue = (hash % COLORS_NB) * (360 / COLORS_NB);
  // monochrome opt: the algorithm allows it — force grayscale (saturation 0).
  var fill = opts.monochrome
    ? "hsl(0 0% " + (opts.monoLightness != null ? opts.monoLightness : 20) + "%)"
    : "hsl(" + hue + " " + saturation + "% " + lightness + "%)";

  var rects = "";
  var n = seed ? 25 : 0;
  for (var i = 0; i < n; i++) {
    // test the 15 lowest-weight bits of the hash (mirrored columns)
    if (hash & (1 << i % 15)) {
      var x = i > 14 ? 7 - ((i / 5) | 0) : (i / 5) | 0;
      var y = i % 5;
      rects += '<rect x="' + x + '" y="' + y + '" width="1" height="1"/>';
    }
  }

  return (
    '<svg viewBox="-1.5 -1.5 8 8" xmlns="http://www.w3.org/2000/svg" fill="' +
    fill +
    '" role="img" aria-label="' +
    esc(seed) +
    '"><title>' +
    esc(seed) +
    "</title>" +
    rects +
    "</svg>"
  );
}

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default { generate: generate };
