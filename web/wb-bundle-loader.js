// wb-bundle-loader — hydrate a served/offline Workbook's embedded filesystem in
// the browser, fully self-contained, ZERO dependencies (native DecompressionStream).
//
// A published Workbook is one .html carrying its filesystem as a base64'd zip in
// <script id="wb-bundle">. On load this reads that block, parses the zip central
// directory, and inflates each entry with DecompressionStream('deflate-raw') —
// matching :zip's per-entry raw-deflate exactly — into an in-memory VFS map
// {path: Uint8Array}, then dispatches `wb:hydrated` for the page's runtime.
//
// Dual-form by design: an ES module (named exports, node --test-able) AND a
// browser IIFE that auto-runs on DOMContentLoaded. The same source ships as the
// referenced static asset and inline-embedded (Bundle.embed_loader/1) for offline.

const SIG_EOCD = 0x06054b50; // End Of Central Directory
const SIG_CDH = 0x02014b50; // Central Directory file Header
const SIG_LFH = 0x04034b50; // Local File Header

// Zip-bomb guard (mirrors Workbooks.Bundle on the host): a few-KB base64 zip can
// inflate to gigabytes and OOM the browser tab. We bound the TOTAL decompressed
// size and each entry's expansion RATIO, checked from the central directory's
// declared sizes BEFORE inflating — and re-checked against the running total as we
// inflate, so a lying header still can't run away. Match the host caps.
const MAX_TOTAL_BYTES = 512 * 1024 * 1024;
const MAX_RATIO = 200;

// base64 → Uint8Array, browser-native (atob); no escaping needed (base64 excludes '<').
export function b64ToBytes(b64) {
  const bin = atob(b64.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Inflate one raw-deflate (method 8) or stored (method 0) slice → Uint8Array.
async function inflate(bytes, method) {
  if (method === 0) return bytes; // stored
  if (method !== 8) throw new Error(`wb-bundle: unsupported zip method ${method}`);
  const stream = new Response(bytes).body.pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// Parse the zip + inflate every entry → Map<path, Uint8Array>. Walks the central
// directory (authoritative), then seeks each Local File Header for the data offset.
export async function parseZip(buf) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const u32 = (o) => dv.getUint32(o, true);
  const u16 = (o) => dv.getUint16(o, true);

  // (1) scan backwards for the EOCD signature (zip comment is rarely present, but
  // the spec allows up to 64KB of it, so we scan rather than assume a fixed tail).
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) {
    if (u32(i) === SIG_EOCD) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("wb-bundle: no EOCD record (not a zip)");

  const count = u16(eocd + 10); // total central dir entries
  let off = u32(eocd + 16); // central dir start offset

  // (2) walk the central directory entries.
  const vfs = new Map();
  let total = 0;
  for (let e = 0; e < count; e++) {
    if (u32(off) !== SIG_CDH) throw new Error("wb-bundle: bad central-dir entry");
    const method = u16(off + 10);
    const compSize = u32(off + 20);
    const uncompSize = u32(off + 24);
    const nameLen = u16(off + 28);
    const extraLen = u16(off + 30);
    const commentLen = u16(off + 32);
    const lho = u32(off + 42); // local-header offset
    const name = new TextDecoder().decode(buf.subarray(off + 46, off + 46 + nameLen));

    // zip-bomb guard (declared sizes): refuse a high-ratio entry or an over-budget
    // total BEFORE inflating, so a malicious tiny payload never expands to GBs.
    if (compSize > 0 && uncompSize > compSize * MAX_RATIO)
      throw new Error(`wb-bundle: entry ${name} exceeds ${MAX_RATIO}× expansion (zip-bomb guard)`);
    total += uncompSize;
    if (total > MAX_TOTAL_BYTES)
      throw new Error(`wb-bundle: archive exceeds ${MAX_TOTAL_BYTES}B uncompressed (zip-bomb guard)`);

    // (3) seek the Local File Header to find the actual data start (its own
    // name/extra lengths may differ from the central dir's).
    if (u32(lho) !== SIG_LFH) throw new Error(`wb-bundle: bad local header for ${name}`);
    const lNameLen = u16(lho + 26);
    const lExtraLen = u16(lho + 28);
    const dataStart = lho + 30 + lNameLen + lExtraLen;
    const slice = buf.subarray(dataStart, dataStart + compSize);

    if (!name.endsWith("/")) {
      const inflated = await inflate(slice, method); // skip dir entries
      // Re-check against the ACTUAL inflated size: a lying header can't run away.
      if (inflated.length > uncompSize + 64 && inflated.length > compSize * MAX_RATIO)
        throw new Error(`wb-bundle: entry ${name} inflated past its declared size (zip-bomb guard)`);
      vfs.set(name, inflated);
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return vfs;
}

// Read the embedded block, hydrate the VFS, dispatch `wb:hydrated`. Returns the
// VFS Map (or null when no bundle is embedded — a plain page, nothing to do).
export async function hydrate(doc = globalThis.document) {
  const el = doc && doc.getElementById && doc.getElementById("wb-bundle");
  if (!el || !el.textContent.trim()) return null;
  const vfs = await parseZip(b64ToBytes(el.textContent));
  globalThis.wbVFS = vfs;
  const target = globalThis.dispatchEvent ? globalThis : doc;
  target.dispatchEvent(new CustomEvent("wb:hydrated", { detail: { vfs } }));
  return vfs;
}

// Browser auto-run. Guarded so the module import under node --test is side-effect
// free (no document there); the served/offline page fires it on DOM ready.
if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => hydrate());
  } else {
    hydrate();
  }
}
