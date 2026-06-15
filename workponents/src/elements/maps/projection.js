// workponents · maps — projections (token-unaware, zero-dep, pure math).
//
// A map is a SPATIAL VIEW OVER A QUERY. The element gets lat/lon off the query
// result; these functions turn (lon, lat) into normalized [0..1] plane coords so
// the view can place them in an abstract themed projection — NO tile provider,
// NO network. The same normalized coords drive pan/zoom (a viewBox transform).
//
// Two projections, both standalone:
//   equirectangular — lon/lat map linearly to x/y (plate carrée). Cheap, global.
//   mercator        — Web Mercator (the basemap projection); matches tile pixels
//                     if/when a Host tile layer is wired, so points stay aligned.

const DEG = Math.PI / 180;
const MERC_MAX_LAT = 85.05112878; // Web Mercator clamp (poles -> infinity)

/** Project [lon, lat] -> normalized [x, y] in [0..1] (y down, like SVG). */
export function project(lon, lat, kind = "mercator") {
  lon = clamp(+lon, -180, 180);
  lat = +lat;
  if (kind === "equirectangular") {
    return [(lon + 180) / 360, (90 - clamp(lat, -90, 90)) / 180];
  }
  // mercator
  lat = clamp(lat, -MERC_MAX_LAT, MERC_MAX_LAT);
  const x = (lon + 180) / 360;
  const s = Math.sin(lat * DEG);
  const y = 0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI);
  return [x, clamp(y, 0, 1)];
}

/** Inverse — normalized [x,y] back to [lon, lat] (for hit-tests / fit). */
export function unproject(x, y, kind = "mercator") {
  if (kind === "equirectangular") {
    return [x * 360 - 180, 90 - y * 180];
  }
  const lon = x * 360 - 180;
  const n = Math.PI - 2 * Math.PI * y;
  const lat = (180 / Math.PI) * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
  return [lon, lat];
}

/** Bounding box (in normalized plane coords) of a set of [lon,lat] points. */
export function bounds(points, kind) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [lon, lat] of points) {
    const [x, y] = project(lon, lat, kind);
    if (x < minX) minX = x; if (y < minY) minY = y;
    if (x > maxX) maxX = x; if (y > maxY) maxY = y;
  }
  if (!isFinite(minX)) return { minX: 0, minY: 0, maxX: 1, maxY: 1 };
  return { minX, minY, maxX, maxY };
}

function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
