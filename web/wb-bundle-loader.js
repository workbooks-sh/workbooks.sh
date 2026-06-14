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
// inflate to gigabytes and OOM the browser tab. The cap is enforced on ACTUAL
// output bytes — we stream-inflate each entry and abort the moment the running
// total exceeds the budget. The central directory's DECLARED sizes are never
// trusted for the stop decision (they're attacker-controlled), so neither a lying
// header nor N tiny-declared entries can run output past the cap.
const MAX_TOTAL_BYTES = 512 * 1024 * 1024; // total ACTUAL inflated, across all entries
const MAX_ENTRY_BYTES = 256 * 1024 * 1024; // per-entry ACTUAL inflated
const MAX_RATIO = 200;

// base64 → Uint8Array, browser-native (atob); no escaping needed (base64 excludes '<').
export function b64ToBytes(b64) {
  const bin = atob(b64.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Inflate one raw-deflate (method 8) or stored (method 0) slice → Uint8Array,
// capped at `budget` ACTUAL output bytes. We read the DecompressionStream chunk
// by chunk and ABORT the moment the running output exceeds the budget — so a
// lying central directory (declared size != actual) can NEVER materialize past
// the cap (the host enforces the same on actual output, not declared sizes).
async function inflate(bytes, method, budget) {
  if (method === 0) {
    if (bytes.length > budget) throw new Error("wb-bundle: stored entry exceeds budget (zip-bomb guard)");
    return bytes; // stored
  }
  if (method !== 8) throw new Error(`wb-bundle: unsupported zip method ${method}`);
  const reader = new Response(bytes).body
    .pipeThrough(new DecompressionStream("deflate-raw"))
    .getReader();
  const chunks = [];
  let len = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    len += value.length;
    if (len > budget) {
      await reader.cancel().catch(() => {});
      throw new Error("wb-bundle: entry inflated past the cap (zip-bomb guard)");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(len);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}

// Parse the zip + inflate every entry → Map<path, Uint8Array>. Walks the central
// directory (authoritative), then seeks each Local File Header for the data offset.
export async function parseZip(buf, opts = {}) {
  const maxTotal = opts.maxTotalBytes ?? MAX_TOTAL_BYTES;
  const maxEntry = opts.maxEntryBytes ?? MAX_ENTRY_BYTES;
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
  let actualTotal = 0; // running ACTUAL inflated bytes — the real cap (declared
                       // sizes are attacker-controlled and are NOT trusted for it).
  for (let e = 0; e < count; e++) {
    if (u32(off) !== SIG_CDH) throw new Error("wb-bundle: bad central-dir entry");
    const method = u16(off + 10);
    const compSize = u32(off + 20);
    const nameLen = u16(off + 28);
    const extraLen = u16(off + 30);
    const commentLen = u16(off + 32);
    const lho = u32(off + 42); // local-header offset
    const name = new TextDecoder().decode(buf.subarray(off + 46, off + 46 + nameLen));

    // (3) seek the Local File Header to find the actual data start (its own
    // name/extra lengths may differ from the central dir's).
    if (u32(lho) !== SIG_LFH) throw new Error(`wb-bundle: bad local header for ${name}`);
    const lNameLen = u16(lho + 26);
    const lExtraLen = u16(lho + 28);
    const dataStart = lho + 30 + lNameLen + lExtraLen;
    const slice = buf.subarray(dataStart, dataStart + compSize);

    if (!name.endsWith("/")) {
      // Budget = the smaller of the per-entry cap and the REMAINING global budget,
      // computed from ACTUAL bytes inflated so far. inflate() aborts mid-stream the
      // moment output exceeds it — so neither a single bomb nor N tiny-declared
      // entries can run total actual output past MAX_TOTAL_BYTES.
      const budget = Math.min(maxEntry, maxTotal - actualTotal);
      const inflated = await inflate(slice, method, budget); // skip dir entries
      actualTotal += inflated.length;
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
