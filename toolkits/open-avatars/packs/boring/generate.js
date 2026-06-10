// boring-avatars — geometric gradient avatars ("marble" + "beam" variants).
// Ported faithfully from https://github.com/boringdesigners/boring-avatars (MIT).
//
// Pure, zero-dep generate(seed, opts) -> SVG string. Same seed → identical SVG.
//   opts.variant : "marble" (default) | "beam"
//   opts.colors  : string[] palette (default: the boring-avatars classic 5)
//   opts.square  : true → square mask instead of a circle
//   opts.size    : px width/height attrs (optional)

// boring-avatars' classic default palette.
var DEFAULT_COLORS = ["#92A1C6", "#146A7C", "#F0AB3D", "#C271B4", "#C20D90"];

// ---- utilities (verbatim from src/lib/utilities.ts) ----

function hashCode(name) {
  var hash = 0;
  for (var i = 0; i < name.length; i++) {
    var character = name.charCodeAt(i);
    hash = (hash << 5) - hash + character;
    hash = hash & hash; // 32-bit
  }
  return Math.abs(hash);
}

function getDigit(number, ntn) {
  return Math.floor((number / Math.pow(10, ntn)) % 10);
}

function getBoolean(number, ntn) {
  return !(getDigit(number, ntn) % 2);
}

function getUnit(number, range, index) {
  var value = number % range;
  if (index && getDigit(number, index) % 2 === 0) {
    return -value;
  }
  return value;
}

function getRandomColor(number, colors, range) {
  return colors[number % range];
}

function getContrast(hexcolor) {
  if (hexcolor.slice(0, 1) === "#") hexcolor = hexcolor.slice(1);
  var r = parseInt(hexcolor.substr(0, 2), 16);
  var g = parseInt(hexcolor.substr(2, 2), 16);
  var b = parseInt(hexcolor.substr(4, 2), 16);
  var yiq = (r * 299 + g * 587 + b * 114) / 1000;
  return yiq >= 128 ? "#000000" : "#FFFFFF";
}

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ---- marble ----

var MARBLE_SIZE = 80;
var MARBLE_ELEMENTS = 3;

function marbleProps(name, colors) {
  var numFromName = hashCode(name);
  var range = colors && colors.length;
  var props = [];
  for (var i = 0; i < MARBLE_ELEMENTS; i++) {
    props.push({
      color: getRandomColor(numFromName + i, colors, range),
      translateX: getUnit(numFromName * (i + 1), MARBLE_SIZE / 10, 1),
      translateY: getUnit(numFromName * (i + 1), MARBLE_SIZE / 10, 2),
      scale: 1.2 + getUnit(numFromName * (i + 1), MARBLE_SIZE / 20) / 10,
      rotate: getUnit(numFromName * (i + 1), 360, 1),
    });
  }
  return props;
}

function marble(seed, opts) {
  var colors = opts.colors || DEFAULT_COLORS;
  var p = marbleProps(seed, colors);
  var S = MARBLE_SIZE;
  // A stable, seed-derived id so two avatars on one page never collide.
  var uid = "bm" + (hashCode(seed) >>> 0).toString(36);
  var maskID = uid + "m";
  var filterID = "filter_" + uid;
  var sizeAttr = opts.size ? ' width="' + opts.size + '" height="' + opts.size + '"' : "";

  var t1 =
    "translate(" + p[1].translateX + " " + p[1].translateY + ") rotate(" + p[1].rotate +
    " " + S / 2 + " " + S / 2 + ") scale(" + p[2].scale + ")";
  var t2 =
    "translate(" + p[2].translateX + " " + p[2].translateY + ") rotate(" + p[2].rotate +
    " " + S / 2 + " " + S / 2 + ") scale(" + p[2].scale + ")";

  return (
    '<svg viewBox="0 0 ' + S + " " + S + '" fill="none" role="img" ' +
    'xmlns="http://www.w3.org/2000/svg"' + sizeAttr + ' aria-label="' + esc(seed) + '">' +
    "<title>" + esc(seed) + "</title>" +
    '<mask id="' + maskID + '" maskUnits="userSpaceOnUse" x="0" y="0" width="' + S + '" height="' + S + '">' +
    '<rect width="' + S + '" height="' + S + '"' + (opts.square ? "" : ' rx="' + S * 2 + '"') + ' fill="#FFFFFF"/>' +
    "</mask>" +
    '<g mask="url(#' + maskID + ')">' +
    '<rect width="' + S + '" height="' + S + '" fill="' + p[0].color + '"/>' +
    '<path filter="url(#' + filterID + ')" ' +
    'd="M32.414 59.35L50.376 70.5H72.5v-71H33.728L26.5 13.381l19.057 27.08L32.414 59.35z" ' +
    'fill="' + p[1].color + '" transform="' + t1 + '"/>' +
    '<path filter="url(#' + filterID + ')" style="mix-blend-mode:overlay" ' +
    'd="M22.216 24L0 46.75l14.108 38.129L78 86l-3.081-59.276-22.378 4.005 12.972 20.186-23.35 27.395L22.215 24z" ' +
    'fill="' + p[2].color + '" transform="' + t2 + '"/>' +
    "</g>" +
    "<defs>" +
    '<filter id="' + filterID + '" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">' +
    '<feFlood flood-opacity="0" result="BackgroundImageFix"/>' +
    '<feBlend in="SourceGraphic" in2="BackgroundImageFix" result="shape"/>' +
    '<feGaussianBlur stdDeviation="7" result="effect1_foregroundBlur"/>' +
    "</filter>" +
    "</defs>" +
    "</svg>"
  );
}

// ---- beam ----

var BEAM_SIZE = 36;

function beamData(name, colors) {
  var numFromName = hashCode(name);
  var range = colors && colors.length;
  var wrapperColor = getRandomColor(numFromName, colors, range);
  var preTranslateX = getUnit(numFromName, 10, 1);
  var wrapperTranslateX = preTranslateX < 5 ? preTranslateX + BEAM_SIZE / 9 : preTranslateX;
  var preTranslateY = getUnit(numFromName, 10, 2);
  var wrapperTranslateY = preTranslateY < 5 ? preTranslateY + BEAM_SIZE / 9 : preTranslateY;
  return {
    wrapperColor: wrapperColor,
    faceColor: getContrast(wrapperColor),
    backgroundColor: getRandomColor(numFromName + 13, colors, range),
    wrapperTranslateX: wrapperTranslateX,
    wrapperTranslateY: wrapperTranslateY,
    wrapperRotate: getUnit(numFromName, 360),
    wrapperScale: 1 + getUnit(numFromName, BEAM_SIZE / 12) / 10,
    isMouthOpen: getBoolean(numFromName, 2),
    isCircle: getBoolean(numFromName, 1),
    eyeSpread: getUnit(numFromName, 5),
    mouthSpread: getUnit(numFromName, 3),
    faceRotate: getUnit(numFromName, 10, 3),
    faceTranslateX:
      wrapperTranslateX > BEAM_SIZE / 6 ? wrapperTranslateX / 2 : getUnit(numFromName, 8, 1),
    faceTranslateY:
      wrapperTranslateY > BEAM_SIZE / 6 ? wrapperTranslateY / 2 : getUnit(numFromName, 7, 2),
  };
}

function beam(seed, opts) {
  var colors = opts.colors || DEFAULT_COLORS;
  var d = beamData(seed, colors);
  var S = BEAM_SIZE;
  var uid = "bb" + (hashCode(seed) >>> 0).toString(36);
  var maskID = uid + "m";
  var sizeAttr = opts.size ? ' width="' + opts.size + '" height="' + opts.size + '"' : "";

  var wrapT =
    "translate(" + d.wrapperTranslateX + " " + d.wrapperTranslateY + ") rotate(" +
    d.wrapperRotate + " " + S / 2 + " " + S / 2 + ") scale(" + d.wrapperScale + ")";
  var faceT =
    "translate(" + d.faceTranslateX + " " + d.faceTranslateY + ") rotate(" +
    d.faceRotate + " " + S / 2 + " " + S / 2 + ")";

  var mouth = d.isMouthOpen
    ? '<path d="M15 ' + (19 + d.mouthSpread) + 'c2 1 4 1 6 0" stroke="' + d.faceColor + '" fill="none" stroke-linecap="round"/>'
    : '<path d="M13,' + (19 + d.mouthSpread) + ' a1,0.75 0 0,0 10,0" fill="' + d.faceColor + '"/>';

  return (
    '<svg viewBox="0 0 ' + S + " " + S + '" fill="none" role="img" ' +
    'xmlns="http://www.w3.org/2000/svg"' + sizeAttr + ' aria-label="' + esc(seed) + '">' +
    "<title>" + esc(seed) + "</title>" +
    '<mask id="' + maskID + '" maskUnits="userSpaceOnUse" x="0" y="0" width="' + S + '" height="' + S + '">' +
    '<rect width="' + S + '" height="' + S + '"' + (opts.square ? "" : ' rx="' + S * 2 + '"') + ' fill="#FFFFFF"/>' +
    "</mask>" +
    '<g mask="url(#' + maskID + ')">' +
    '<rect width="' + S + '" height="' + S + '" fill="' + d.backgroundColor + '"/>' +
    '<rect x="0" y="0" width="' + S + '" height="' + S + '" transform="' + wrapT + '" fill="' +
    d.wrapperColor + '" rx="' + (d.isCircle ? S : S / 6) + '"/>' +
    '<g transform="' + faceT + '">' +
    mouth +
    '<rect x="' + (14 - d.eyeSpread) + '" y="14" width="1.5" height="2" rx="1" stroke="none" fill="' + d.faceColor + '"/>' +
    '<rect x="' + (20 + d.eyeSpread) + '" y="14" width="1.5" height="2" rx="1" stroke="none" fill="' + d.faceColor + '"/>' +
    "</g>" +
    "</g>" +
    "</svg>"
  );
}

export function generate(seed, opts) {
  seed = seed == null ? "" : String(seed);
  opts = opts || {};
  return (opts.variant === "beam" ? beam : marble)(seed, opts);
}

export default { generate: generate };
