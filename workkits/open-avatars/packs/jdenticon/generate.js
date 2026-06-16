// jdenticon — the Jdenticon identicon algorithm → SVG.
// Ported faithfully from https://github.com/dmester/jdenticon (MIT).
//
// Pure, zero-dep generate(seed, opts) -> SVG string. Same seed → identical SVG.
// The seed is SHA1-hashed (exactly as jdenticon does) and the icon is generated
// from that hex hash, so output matches the upstream library byte-for-byte
// (modulo whitespace) for the same input.
//   opts.size       : px for the svg width/height + viewBox (default 100)
//   opts.padding    : icon padding ratio (default 0.08, jdenticon's default)
//   opts.monochrome : force grayscale (colorSaturation/grayscale → 0)
//   opts.background  : background fill (default none/transparent)

// ---------- SHA1 (verbatim port of src/common/sha1.js) ----------
function sha1(message) {
  var HASH_SIZE_HALF_BYTES = 40;
  var BLOCK_SIZE_WORDS = 16;
  var i = 0,
    f = 0,
    urlEncodedMessage = encodeURI(message) + "%80",
    data = [],
    dataSize,
    hashBuffer = [],
    a = 0x67452301,
    b = 0xefcdab89,
    c = ~a,
    d = ~b,
    e = 0xc3d2e1f0,
    hash = [a, b, c, d, e],
    blockStartIndex = 0,
    hexHash = "";

  function rotl(value, shift) {
    return (value << shift) | (value >>> (32 - shift));
  }

  for (; i < urlEncodedMessage.length; f++) {
    data[f >> 2] =
      data[f >> 2] |
      ((urlEncodedMessage[i] == "%"
        ? parseInt(urlEncodedMessage.substring(i + 1, (i += 3)), 16)
        : urlEncodedMessage.charCodeAt(i++)) <<
        ((3 - (f & 3)) * 8));
  }

  dataSize = (((f + 7) >> 6) + 1) * BLOCK_SIZE_WORDS;
  data[dataSize - 1] = f * 8 - 8;

  for (; blockStartIndex < dataSize; blockStartIndex += BLOCK_SIZE_WORDS) {
    for (i = 0; i < 80; i++) {
      f =
        rotl(a, 5) +
        e +
        (i < 20
          ? ((b & c) ^ (~b & d)) + 0x5a827999
          : i < 40
          ? (b ^ c ^ d) + 0x6ed9eba1
          : i < 60
          ? ((b & c) ^ (b & d) ^ (c & d)) + 0x8f1bbcdc
          : (b ^ c ^ d) + 0xca62c1d6) +
        (hashBuffer[i] =
          i < BLOCK_SIZE_WORDS
            ? data[blockStartIndex + i] | 0
            : rotl(
                hashBuffer[i - 3] ^ hashBuffer[i - 8] ^ hashBuffer[i - 14] ^ hashBuffer[i - 16],
                1
              ));
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = f;
    }
    hash[0] = a = (hash[0] + a) | 0;
    hash[1] = b = (hash[1] + b) | 0;
    hash[2] = c = (hash[2] + c) | 0;
    hash[3] = d = (hash[3] + d) | 0;
    hash[4] = e = (hash[4] + e) | 0;
  }

  for (i = 0; i < HASH_SIZE_HALF_BYTES; i++) {
    hexHash += ((hash[i >> 3] >>> ((7 - (i & 7)) * 4)) & 0xf).toString(16);
  }
  return hexHash;
}

// ---------- parseHex ----------
function parseHex(hash, startPosition, octets) {
  return parseInt(hash.substr(startPosition, octets), 16);
}

// ---------- color (verbatim port of src/renderer/color.js) ----------
function decToHex(v) {
  v |= 0;
  return v < 0 ? "00" : v < 16 ? "0" + v.toString(16) : v < 256 ? v.toString(16) : "ff";
}
function hueToRgb(m1, m2, h) {
  h = h < 0 ? h + 6 : h > 6 ? h - 6 : h;
  return decToHex(
    255 * (h < 1 ? m1 + (m2 - m1) * h : h < 3 ? m2 : h < 4 ? m1 + (m2 - m1) * (4 - h) : m1)
  );
}
function hsl(hue, saturation, lightness) {
  var result;
  if (saturation == 0) {
    var partialHex = decToHex(lightness * 255);
    result = partialHex + partialHex + partialHex;
  } else {
    var m2 =
      lightness <= 0.5
        ? lightness * (saturation + 1)
        : lightness + saturation - lightness * saturation;
    var m1 = lightness * 2 - m2;
    result =
      hueToRgb(m1, m2, hue * 6 + 2) + hueToRgb(m1, m2, hue * 6) + hueToRgb(m1, m2, hue * 6 - 2);
  }
  return "#" + result;
}
function correctedHsl(hue, saturation, lightness) {
  var correctors = [0.55, 0.5, 0.5, 0.46, 0.6, 0.55, 0.55];
  var corrector = correctors[(hue * 6 + 0.5) | 0];
  lightness =
    lightness < 0.5
      ? lightness * corrector * 2
      : corrector + (lightness - 0.5) * (1 - corrector) * 2;
  return hsl(hue, saturation, lightness);
}

// ---------- colorTheme ----------
function colorTheme(hue, cfg) {
  return [
    correctedHsl(hue, cfg.grayscaleSaturation, cfg.grayscaleLightness(0)),
    correctedHsl(hue, cfg.colorSaturation, cfg.colorLightness(0.5)),
    correctedHsl(hue, cfg.grayscaleSaturation, cfg.grayscaleLightness(1)),
    correctedHsl(hue, cfg.colorSaturation, cfg.colorLightness(1)),
    correctedHsl(hue, cfg.colorSaturation, cfg.colorLightness(0)),
  ];
}

// ---------- Transform / Point ----------
function Point(x, y) {
  this.x = x;
  this.y = y;
}
function Transform(x, y, size, rotation) {
  this._x = x;
  this._y = y;
  this._size = size;
  this._rotation = rotation;
}
Transform.prototype.transformIconPoint = function (x, y, w, h) {
  var right = this._x + this._size,
    bottom = this._y + this._size,
    rotation = this._rotation;
  return rotation === 1
    ? new Point(right - y - (h || 0), this._y + x)
    : rotation === 2
    ? new Point(right - x - (w || 0), bottom - y - (h || 0))
    : rotation === 3
    ? new Point(this._x + y, bottom - x - (w || 0))
    : new Point(this._x + x, this._y + y);
};
var NO_TRANSFORM = new Transform(0, 0, 0, 0);

// ---------- SvgPath (verbatim port of src/renderer/svg/svgPath.js) ----------
function svgValue(value) {
  return ((value * 10 + 0.5) | 0) / 10;
}
function SvgPath() {
  this.dataString = "";
}
SvgPath.prototype.addPolygon = function (points) {
  var dataString = "";
  for (var i = 0; i < points.length; i++) {
    dataString += (i ? "L" : "M") + svgValue(points[i].x) + " " + svgValue(points[i].y);
  }
  this.dataString += dataString + "Z";
};
SvgPath.prototype.addCircle = function (point, diameter, counterClockwise) {
  var sweepFlag = counterClockwise ? 0 : 1,
    svgRadius = svgValue(diameter / 2),
    svgDiameter = svgValue(diameter),
    svgArc = "a" + svgRadius + "," + svgRadius + " 0 1," + sweepFlag + " ";
  this.dataString +=
    "M" +
    svgValue(point.x) +
    " " +
    svgValue(point.y + diameter / 2) +
    svgArc +
    svgDiameter +
    ",0" +
    svgArc +
    -svgDiameter +
    ",0";
};

// ---------- renderer collecting paths by color ----------
function SvgCollector() {
  this._pathsByColor = {};
}
SvgCollector.prototype.beginShape = function (color) {
  this._path = this._pathsByColor[color] || (this._pathsByColor[color] = new SvgPath());
};
SvgCollector.prototype.endShape = function () {};
SvgCollector.prototype.addPolygon = function (points) {
  this._path.addPolygon(points);
};
SvgCollector.prototype.addCircle = function (point, diameter, ccw) {
  this._path.addCircle(point, diameter, ccw);
};

// ---------- Graphics (verbatim port of src/renderer/graphics.js) ----------
function Graphics(renderer) {
  this._renderer = renderer;
  this.currentTransform = NO_TRANSFORM;
}
Graphics.prototype.addPolygon = function (points, invert) {
  var di = invert ? -2 : 2,
    transformedPoints = [];
  for (var i = invert ? points.length - 2 : 0; i < points.length && i >= 0; i += di) {
    transformedPoints.push(this.currentTransform.transformIconPoint(points[i], points[i + 1]));
  }
  this._renderer.addPolygon(transformedPoints);
};
Graphics.prototype.addCircle = function (x, y, size, invert) {
  var p = this.currentTransform.transformIconPoint(x, y, size, size);
  this._renderer.addCircle(p, size, invert);
};
Graphics.prototype.addRectangle = function (x, y, w, h, invert) {
  this.addPolygon([x, y, x + w, y, x + w, y + h, x, y + h], invert);
};
Graphics.prototype.addTriangle = function (x, y, w, h, r, invert) {
  var points = [x + w, y, x + w, y + h, x, y + h, x, y];
  points.splice(((r || 0) % 4) * 2, 2);
  this.addPolygon(points, invert);
};
Graphics.prototype.addRhombus = function (x, y, w, h, invert) {
  this.addPolygon([x + w / 2, y, x + w, y + h / 2, x + w / 2, y + h, x, y + h / 2], invert);
};

// ---------- shapes (verbatim port of src/renderer/shapes.js) ----------
function centerShape(index, g, cell, positionIndex) {
  index = index % 14;
  var k, m, w, h, inner, outer;
  if (!index) {
    k = cell * 0.42;
    g.addPolygon([0, 0, cell, 0, cell, cell - k * 2, cell - k, cell, 0, cell]);
  } else if (index == 1) {
    w = 0 | (cell * 0.5);
    h = 0 | (cell * 0.8);
    g.addTriangle(cell - w, 0, w, h, 2);
  } else if (index == 2) {
    w = 0 | (cell / 3);
    g.addRectangle(w, w, cell - w, cell - w);
  } else if (index == 3) {
    inner = cell * 0.1;
    outer = cell < 6 ? 1 : cell < 8 ? 2 : 0 | (cell * 0.25);
    inner = inner > 1 ? 0 | inner : inner > 0.5 ? 1 : inner;
    g.addRectangle(outer, outer, cell - inner - outer, cell - inner - outer);
  } else if (index == 4) {
    m = 0 | (cell * 0.15);
    w = 0 | (cell * 0.5);
    g.addCircle(cell - w - m, cell - w - m, w);
  } else if (index == 5) {
    inner = cell * 0.1;
    outer = inner * 4;
    if (outer > 3) outer = 0 | outer;
    g.addRectangle(0, 0, cell, cell);
    g.addPolygon(
      [outer, outer, cell - inner, outer, outer + (cell - outer - inner) / 2, cell - inner],
      true
    );
  } else if (index == 6) {
    g.addPolygon([
      0,
      0,
      cell,
      0,
      cell,
      cell * 0.7,
      cell * 0.4,
      cell * 0.4,
      cell * 0.7,
      cell,
      0,
      cell,
    ]);
  } else if (index == 7) {
    g.addTriangle(cell / 2, cell / 2, cell / 2, cell / 2, 3);
  } else if (index == 8) {
    g.addRectangle(0, 0, cell, cell / 2);
    g.addRectangle(0, cell / 2, cell / 2, cell / 2);
    g.addTriangle(cell / 2, cell / 2, cell / 2, cell / 2, 1);
  } else if (index == 9) {
    inner = cell * 0.14;
    outer = cell < 4 ? 1 : cell < 6 ? 2 : 0 | (cell * 0.35);
    inner = cell < 8 ? inner : 0 | inner;
    g.addRectangle(0, 0, cell, cell);
    g.addRectangle(outer, outer, cell - outer - inner, cell - outer - inner, true);
  } else if (index == 10) {
    inner = cell * 0.12;
    outer = inner * 3;
    g.addRectangle(0, 0, cell, cell);
    g.addCircle(outer, outer, cell - inner - outer, true);
  } else if (index == 11) {
    g.addTriangle(cell / 2, cell / 2, cell / 2, cell / 2, 3);
  } else if (index == 12) {
    m = cell * 0.25;
    g.addRectangle(0, 0, cell, cell);
    g.addRhombus(m, m, cell - m, cell - m, true);
  } else {
    // 13
    if (!positionIndex) {
      m = cell * 0.4;
      w = cell * 1.2;
      g.addCircle(m, m, w);
    }
  }
}

function outerShape(index, g, cell) {
  index = index % 4;
  var m;
  if (!index) {
    g.addTriangle(0, 0, cell, cell, 0);
  } else if (index == 1) {
    g.addTriangle(0, cell / 2, cell, cell / 2, 0);
  } else if (index == 2) {
    g.addRhombus(0, 0, cell, cell);
  } else {
    m = cell / 6;
    g.addCircle(m, m, cell - 2 * m);
  }
}

// ---------- iconGenerator (verbatim port of src/renderer/iconGenerator.js) ----------
function generateIcon(renderer, hash, iconSize, cfg) {
  var size = iconSize;
  var padding = (0.5 + size * cfg.iconPadding) | 0;
  size -= padding * 2;

  var graphics = new Graphics(renderer);
  var cell = 0 | (size / 4);
  var x = 0 | (padding + size / 2 - cell * 2);
  var y = 0 | (padding + size / 2 - cell * 2);

  var hue = parseHex(hash, -7) / 0xfffffff;
  var availableColors = colorTheme(hue, cfg);
  var selectedColorIndexes = [];
  var index;

  function isDuplicate(values) {
    if (values.indexOf(index) >= 0) {
      for (var i = 0; i < values.length; i++) {
        if (selectedColorIndexes.indexOf(values[i]) >= 0) return true;
      }
    }
  }

  for (var i = 0; i < 3; i++) {
    index = parseHex(hash, 8 + i, 1) % availableColors.length;
    if (isDuplicate([0, 4]) || isDuplicate([2, 3])) index = 1;
    selectedColorIndexes.push(index);
  }

  function renderShape(colorIndex, shapes, idx, rotationIndex, positions) {
    var shapeIndex = parseHex(hash, idx, 1);
    var r = rotationIndex ? parseHex(hash, rotationIndex, 1) : 0;
    renderer.beginShape(availableColors[selectedColorIndexes[colorIndex]]);
    for (var i = 0; i < positions.length; i++) {
      graphics.currentTransform = new Transform(
        x + positions[i][0] * cell,
        y + positions[i][1] * cell,
        cell,
        r++ % 4
      );
      shapes(shapeIndex, graphics, cell, i);
    }
    renderer.endShape();
  }

  // Sides
  renderShape(0, outerShape, 2, 3, [[1, 0], [2, 0], [2, 3], [1, 3], [0, 1], [3, 1], [3, 2], [0, 2]]);
  // Corners
  renderShape(1, outerShape, 4, 5, [[0, 0], [3, 0], [3, 3], [0, 3]]);
  // Center
  renderShape(2, centerShape, 1, null, [[1, 1], [2, 1], [2, 2], [1, 2]]);
}

// ---------- configuration (jdenticon defaults) ----------
function lightnessFn(range) {
  return function (value) {
    var v = range[0] + value * (range[1] - range[0]);
    return v < 0 ? 0 : v > 1 ? 1 : v;
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
  var size = opts.size != null ? opts.size : 100;
  var hash = sha1(seed);

  // jdenticon's default config (src/common/configuration.js getConfiguration):
  //   colorSaturation 0.5, grayscaleSaturation 0,
  //   colorLightness [0.4,0.8], grayscaleLightness [0.3,0.9], padding 0.08
  var cfg = {
    hue: function (h) {
      return h;
    },
    colorSaturation: opts.monochrome ? 0 : 0.5,
    grayscaleSaturation: 0,
    colorLightness: lightnessFn(opts.monochrome ? [0.27, 0.27] : [0.4, 0.8]),
    grayscaleLightness: lightnessFn([0.3, 0.9]),
    iconPadding: opts.padding != null ? opts.padding : 0.08,
  };

  var collector = new SvgCollector();
  generateIcon(collector, hash, size, cfg);

  var paths = "";
  var byColor = collector._pathsByColor;
  for (var color in byColor) {
    if (byColor.hasOwnProperty(color)) {
      paths += '<path fill="' + color + '" d="' + byColor[color].dataString + '"/>';
    }
  }

  var bg = opts.background
    ? '<rect width="' + size + '" height="' + size + '" fill="' + esc(opts.background) + '"/>'
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
    paths +
    "</svg>"
  );
}

export default { generate: generate };
