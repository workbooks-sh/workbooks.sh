// pixitar — pixel-art avatars rendered as scaled rects on a grid → SVG.
// Inspired by https://github.com/ptcodes/pixitar (MIT).
//
// DEVIATION NOTE (honest attribution): the upstream ptcodes/pixitar is a Ruby
// gem that COMPOSES a PNG from random asset image files (it calls Array#sample,
// so it is non-deterministic and ships no algorithmic grid generator). That
// design cannot be ported as a pure, deterministic seed→SVG function without its
// (unshipped) PNG assets. This port keeps pixitar's INTENT — blocky pixel-art
// avatars on a grid — as a deterministic, zero-dep generator: a seeded,
// vertically-mirrored pixel grid drawn as scaled <rect>s, seed-hued.
//
// Pure generate(seed, opts) -> SVG. Same seed → identical SVG.
//   opts.size       : px width/height (default 120)
//   opts.grid       : odd grid dimension (default 7; columns mirrored)
//   opts.background : backplate fill (default "#f4f4f2")
//   opts.monochrome : force grayscale ink

// FNV-1a 32-bit — the toolkit's house hash, so pixitar shares the determinism
// contract with the core selector.
function fnv1a(str) {
  var h = 0x811c9dc5;
  for (var i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

// A tiny deterministic PRNG seeded from the hash (mulberry32) so we can draw as
// many independent bits as the grid needs, all determined by the seed.
function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    var t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function generate(seed, opts) {
  seed = seed == null ? "" : String(seed);
  opts = opts || {};
  var size = opts.size != null ? opts.size : 120;
  var grid = opts.grid != null ? opts.grid : 7; // columns mirrored about center
  if (grid % 2 === 0) grid += 1;

  var hash = fnv1a(seed);
  var rnd = mulberry32(hash);

  // Seed-derived hue, like pixitar's colorful sprites; B&W when monochrome.
  var hue = hash % 360;
  var ink = opts.monochrome ? "hsl(0 0% 22%)" : "hsl(" + hue + " 62% 45%)";

  var cell = size / grid;
  var half = (grid + 1) / 2; // columns 0..half-1, mirrored to the right
  var rects = "";

  for (var y = 0; y < grid; y++) {
    for (var x = 0; x < half; x++) {
      // ~45% fill, deterministic per (x,y)
      if (rnd() < 0.45) {
        var px = (x * cell).toFixed(2);
        var py = (y * cell).toFixed(2);
        var w = cell.toFixed(2);
        rects += '<rect x="' + px + '" y="' + py + '" width="' + w + '" height="' + w + '"/>';
        var mx = grid - 1 - x;
        if (mx !== x) {
          rects +=
            '<rect x="' + (mx * cell).toFixed(2) + '" y="' + py + '" width="' + w + '" height="' + w + '"/>';
        }
      }
    }
  }

  var bg =
    opts.background !== ""
      ? '<rect width="' + size + '" height="' + size + '" fill="' +
        esc(opts.background != null ? opts.background : "#f4f4f2") + '"/>'
      : "";

  return (
    '<svg xmlns="http://www.w3.org/2000/svg" width="' +
    size +
    '" height="' +
    size +
    '" viewBox="0 0 ' +
    size +
    " " +
    size +
    '" role="img" aria-label="' +
    esc(seed) +
    '"><title>' +
    esc(seed) +
    "</title>" +
    bg +
    '<g fill="' +
    ink +
    '">' +
    rects +
    "</g></svg>"
  );
}

export default { generate: generate };
