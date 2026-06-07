// Asset format probes — answer the postmortem's "are logos PNG or SVG, what
// dimensions, are they real?" question with hard data.
//
// Used by both the eval runner (assert quality) and the agent dispatcher
// (decide whether to re-attempt the logo cascade with different sources).
//
// No vendor dependencies. Pure HTTP fetch + binary header parsing.

import { browserHeaders } from "../scrape/headers.js";

export type ImageFormat = "svg" | "png" | "jpeg" | "gif" | "webp" | "ico" | "avif" | "unknown";

export interface LogoProbe {
  url: string;
  /** Network roundtrip succeeded with a 2xx + image content-type. */
  reachable: boolean;
  reason?: string;
  format: ImageFormat;
  bytes: number;
  /** Pixel dimensions (only for raster formats we can parse the header of). */
  width?: number;
  height?: number;
  /** Does the file have a transparent background? (SVG: heuristic; PNG: header check.) */
  transparent?: boolean;
  /** SVG-only: number of <path>/<rect>/<polygon> elements as a complexity proxy. */
  svg_path_count?: number;
  /** Score from 0-100. Use for cascade picking ("if score < 30, try next source"). */
  quality_score: number;
  notes: string[];
}

const FETCH_TIMEOUT_MS = 6000;
const MAX_BYTES_DOWNLOAD = 512_000; // skip if larger; logos shouldn't be >500KB

// ── Format detection ─────────────────────────────────────────────────────────

function detectFormatFromHeader(bytes: Uint8Array, contentType: string): ImageFormat {
  // Magic bytes — more reliable than content-type when CDN lies.
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpeg";
  if (bytes.length >= 6 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return "gif";
  if (bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x00 && bytes[2] === 0x01 && bytes[3] === 0x00) return "ico";
  if (bytes.length >= 12 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return "webp";
  if (bytes.length >= 12 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70 && bytes[8] === 0x61 && bytes[9] === 0x76 && bytes[10] === 0x69 && bytes[11] === 0x66) return "avif";
  // SVG starts with "<?xml" or "<svg" (sometimes with BOM / whitespace).
  const head = new TextDecoder().decode(bytes.slice(0, 200)).trim().toLowerCase();
  if (head.startsWith("<?xml") || head.startsWith("<svg")) return "svg";
  if (contentType.includes("svg")) return "svg";
  return "unknown";
}

// PNG: width + height live at bytes 16-23 (big-endian uint32).
function pngDims(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length < 24) return null;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: dv.getUint32(16, false), height: dv.getUint32(20, false) };
}

// PNG: color-type byte at offset 25; 4 (grayscale+alpha) or 6 (truecolor+alpha) = transparent.
function pngTransparent(bytes: Uint8Array): boolean {
  if (bytes.length < 26) return false;
  const colorType = bytes[25];
  return colorType === 4 || colorType === 6;
}

// JPEG: scan SOF0/SOF2 markers for dimensions. Cap scan to first 64KB.
function jpegDims(bytes: Uint8Array): { width: number; height: number } | null {
  let i = 2;
  const cap = Math.min(bytes.length - 9, 64_000);
  while (i < cap) {
    if (bytes[i] !== 0xff) { i++; continue; }
    const marker = bytes[i + 1]!;
    if (marker === 0xc0 || marker === 0xc1 || marker === 0xc2) {
      const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const h = dv.getUint16(i + 5, false);
      const w = dv.getUint16(i + 7, false);
      return { width: w, height: h };
    }
    if (marker >= 0xd0 && marker <= 0xd9) { i += 2; continue; }
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const segLen = dv.getUint16(i + 2, false);
    i += 2 + segLen;
  }
  return null;
}

// GIF: dimensions at bytes 6-9 (little-endian uint16).
function gifDims(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length < 10) return null;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: dv.getUint16(6, true), height: dv.getUint16(8, true) };
}

// WebP: VP8 / VP8L / VP8X chunks carry dimensions.
function webpDims(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length < 30) return null;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  // VP8 (lossy): width/height at offset 26 (16-bit LE).
  const sig = new TextDecoder().decode(bytes.slice(12, 16));
  if (sig === "VP8 ") return { width: dv.getUint16(26, true) & 0x3fff, height: dv.getUint16(28, true) & 0x3fff };
  if (sig === "VP8L") {
    // 14-bit packed dimensions at offset 21.
    const b0 = bytes[21]!, b1 = bytes[22]!, b2 = bytes[23]!, b3 = bytes[24]!;
    const w = 1 + ((b1 & 0x3f) << 8 | b0);
    const h = 1 + ((b3 & 0x0f) << 10 | b2 << 2 | (b1 & 0xc0) >> 6);
    return { width: w, height: h };
  }
  if (sig === "VP8X") {
    const w = 1 + (bytes[24]! | bytes[25]! << 8 | bytes[26]! << 16);
    const h = 1 + (bytes[27]! | bytes[28]! << 8 | bytes[29]! << 16);
    return { width: w, height: h };
  }
  return null;
}

// SVG: parse viewBox / width / height from the first <svg> tag.
function svgInfo(bytes: Uint8Array): { width?: number; height?: number; svg_path_count: number; transparent: boolean } {
  const text = new TextDecoder().decode(bytes.slice(0, 8000));
  const m = text.match(/<svg[^>]*>/i);
  const widthAttr = m?.[0].match(/\bwidth=["']([\d.]+)/)?.[1];
  const heightAttr = m?.[0].match(/\bheight=["']([\d.]+)/)?.[1];
  const viewBox = m?.[0].match(/\bviewBox=["']([\d.\s,-]+)["']/i)?.[1]?.trim().split(/\s+|,/).map(Number);
  let width: number | undefined;
  let height: number | undefined;
  if (widthAttr) width = Number(widthAttr);
  if (heightAttr) height = Number(heightAttr);
  if ((!width || !height) && viewBox && viewBox.length === 4) {
    width = width ?? viewBox[2];
    height = height ?? viewBox[3];
  }
  // Path count = rough complexity proxy (1×1 pixel SVGs have 0; real logos have ≥1).
  const pathCount = (text.match(/<(?:path|rect|polygon|polyline|circle|ellipse)\b/gi) ?? []).length;
  // Background-transparent if no opaque <rect width=100% height=100% fill="…">.
  const opaqueBg = /<rect[^>]+(?:width=["']100%["']|width=["']\d{2,4}["'])[^>]+fill=["']#?[0-9a-f]/i.test(text);
  return { width, height, svg_path_count: pathCount, transparent: !opaqueBg };
}

// ── Quality scoring ──────────────────────────────────────────────────────────
//
// 100 = perfect (real SVG with viewBox, multiple paths, transparent bg)
//  60 = acceptable raster (PNG 256+px, transparent)
//  40 = small raster or low-detail SVG
//  20 = favicon-sized (32-64px)
//   0 = unreachable / unknown
function scoreQuality(p: Pick<LogoProbe, "format" | "bytes" | "width" | "height" | "transparent" | "svg_path_count">): number {
  if (p.format === "unknown") return 0;
  let s = 0;
  if (p.format === "svg") {
    s += 50;
    if ((p.svg_path_count ?? 0) >= 1) s += 20;
    if ((p.svg_path_count ?? 0) >= 3) s += 10;
    if (p.transparent) s += 10;
    if ((p.width ?? 0) >= 64 && (p.height ?? 0) >= 64) s += 10;
  } else if (p.format === "png") {
    if ((p.width ?? 0) >= 512) s += 60;
    else if ((p.width ?? 0) >= 256) s += 50;
    else if ((p.width ?? 0) >= 128) s += 40;
    else if ((p.width ?? 0) >= 64) s += 30;
    else s += 20;
    if (p.transparent) s += 15;
    if (p.bytes >= 4000) s += 10;
  } else if (p.format === "jpeg" || p.format === "webp" || p.format === "avif") {
    if ((p.width ?? 0) >= 256) s += 40;
    else s += 20;
    if (p.bytes >= 4000) s += 10;
  } else if (p.format === "ico") {
    s += 20; // favicons are rarely a "real" logo
  }
  return Math.max(0, Math.min(100, s));
}

// ── Public API ───────────────────────────────────────────────────────────────

export async function probeLogo(url: string): Promise<LogoProbe> {
  const out: LogoProbe = {
    url, reachable: false, format: "unknown", bytes: 0, quality_score: 0, notes: [],
  };
  if (!url) { out.reason = "no url"; return out; }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  let r: Response;
  try {
    r = await fetch(url, {
      method: "GET",
      redirect: "follow",
      signal: ctrl.signal,
      // Realistic Chrome fingerprint — many image CDNs gate on UA / Sec-Fetch.
      headers: browserHeaders({
        accept: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        "sec-fetch-dest": "image",
        "sec-fetch-mode": "no-cors",
      }),
    });
  } catch (e) {
    clearTimeout(t);
    out.reason = `fetch threw: ${(e as Error).message}`;
    return out;
  }
  clearTimeout(t);
  if (!r.ok) { out.reason = `HTTP ${r.status}`; return out; }
  const ct = (r.headers.get("content-type") ?? "").toLowerCase();
  if (!ct.startsWith("image/") && !ct.includes("svg") && !ct.includes("octet-stream")) {
    out.reason = `not image content-type: ${ct.slice(0, 40)}`;
    return out;
  }
  let bytes: Uint8Array;
  try {
    const buf = await r.arrayBuffer();
    if (buf.byteLength > MAX_BYTES_DOWNLOAD) {
      out.reason = `too large (${buf.byteLength}B > ${MAX_BYTES_DOWNLOAD}B cap)`;
      return out;
    }
    bytes = new Uint8Array(buf);
  } catch (e) {
    out.reason = `body read failed: ${(e as Error).message}`;
    return out;
  }
  out.reachable = true;
  out.bytes = bytes.length;
  out.format = detectFormatFromHeader(bytes, ct);

  if (out.format === "png") {
    const d = pngDims(bytes);
    if (d) { out.width = d.width; out.height = d.height; }
    out.transparent = pngTransparent(bytes);
  } else if (out.format === "jpeg") {
    const d = jpegDims(bytes);
    if (d) { out.width = d.width; out.height = d.height; }
    out.transparent = false;
  } else if (out.format === "gif") {
    const d = gifDims(bytes);
    if (d) { out.width = d.width; out.height = d.height; }
  } else if (out.format === "webp") {
    const d = webpDims(bytes);
    if (d) { out.width = d.width; out.height = d.height; }
  } else if (out.format === "svg") {
    const info = svgInfo(bytes);
    out.width = info.width;
    out.height = info.height;
    out.svg_path_count = info.svg_path_count;
    out.transparent = info.transparent;
  }

  out.quality_score = scoreQuality(out);

  // Surface notable observations.
  if (out.bytes < 1024) out.notes.push("<1KB — may be 1×1 pixel placeholder");
  if (out.format === "svg" && (out.svg_path_count ?? 0) === 0) out.notes.push("SVG has no path/shape elements");
  if (out.format === "png" && (out.width ?? 0) < 64) out.notes.push("PNG smaller than 64px");
  if (out.format === "ico") out.notes.push("favicon format (low quality for hero use)");
  return out;
}

/** Probe a list of candidate logo URLs and return them sorted by quality. */
export async function probeAndRank(urls: string[]): Promise<LogoProbe[]> {
  const probes = await Promise.all(urls.map((u) => probeLogo(u)));
  return probes.sort((a, b) => b.quality_score - a.quality_score);
}
