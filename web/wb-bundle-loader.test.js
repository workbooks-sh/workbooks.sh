// Unit-test the dependency-free browser bundle loader. Builds a real ZIP by hand
// (raw-deflate, method 8 — exactly what :zip emits — plus a stored method-0 entry
// and a directory entry to skip) and asserts parseZip recovers each entry
// byte-exact through DecompressionStream. Run: node --test web/wb-bundle-loader.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { deflateRawSync, crc32 } from "node:zlib";
import { b64ToBytes, parseZip } from "./wb-bundle-loader.js";

const enc = new TextEncoder();

// Minimal ZIP writer: each entry {name, data, store?} → a valid archive buffer
// (local headers + central directory + EOCD), little-endian per PKZIP spec.
function makeZip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;

  for (const e of entries) {
    const nameB = enc.encode(e.name);
    const isDir = e.name.endsWith("/");
    const raw = e.data ? (e.data instanceof Uint8Array ? e.data : enc.encode(e.data)) : new Uint8Array(0);
    const method = isDir || e.store ? 0 : 8;
    const comp = method === 8 ? new Uint8Array(deflateRawSync(raw)) : raw;
    const crc = crc32(raw) >>> 0;

    const lfh = new DataView(new ArrayBuffer(30));
    lfh.setUint32(0, 0x04034b50, true);
    lfh.setUint16(4, 20, true);
    lfh.setUint16(8, method, true);
    lfh.setUint32(14, crc, true);
    lfh.setUint32(18, comp.length, true);
    // e.declUncomp lets a test LIE about the declared uncompressed size (attacker
    // forging the header). The loader must ignore it and cap on ACTUAL output.
    const declUncomp = e.declUncomp ?? raw.length;
    lfh.setUint32(22, declUncomp, true);
    lfh.setUint16(26, nameB.length, true);
    locals.push(new Uint8Array(lfh.buffer), nameB, comp);

    const cdh = new DataView(new ArrayBuffer(46));
    cdh.setUint32(0, 0x02014b50, true);
    cdh.setUint16(10, method, true);
    cdh.setUint32(16, crc, true);
    cdh.setUint32(20, comp.length, true);
    cdh.setUint32(24, declUncomp, true);
    cdh.setUint16(28, nameB.length, true);
    cdh.setUint32(42, offset, true);
    centrals.push(new Uint8Array(cdh.buffer), nameB);

    offset += 30 + nameB.length + comp.length;
  }

  const cdStart = offset;
  const cdParts = centrals.flatMap((p) => [...p]);
  const cdLen = cdParts.length;

  const eocd = new DataView(new ArrayBuffer(22));
  eocd.setUint32(0, 0x06054b50, true);
  eocd.setUint16(8, entries.length, true);
  eocd.setUint16(10, entries.length, true);
  eocd.setUint32(12, cdLen, true);
  eocd.setUint32(16, cdStart, true);

  const all = [...locals.flatMap((p) => [...p]), ...cdParts, ...new Uint8Array(eocd.buffer)];
  return new Uint8Array(all);
}

test("parseZip inflates deflate (8) + stored (0), skips dir entries", async () => {
  const zip = makeZip([
    { name: "index.html", data: "<h1>" + "x".repeat(500) + "</h1>" }, // method 8
    { name: "data/raw.bin", data: new Uint8Array([1, 2, 3, 255, 0, 7]), store: true }, // method 0
    { name: "data/", data: "" }, // directory entry — must be skipped
  ]);

  const vfs = await parseZip(zip);
  assert.equal(vfs.size, 2, "directory entry skipped");
  assert.equal(new TextDecoder().decode(vfs.get("index.html")), "<h1>" + "x".repeat(500) + "</h1>");
  assert.deepEqual([...vfs.get("data/raw.bin")], [1, 2, 3, 255, 0, 7]);
});

test("b64ToBytes round-trips the embedded-block encoding", async () => {
  const zip = makeZip([{ name: "a.txt", data: "hello bundle" }]);
  const b64 = Buffer.from(zip).toString("base64"); // == Elixir Base.encode64
  const vfs = await parseZip(b64ToBytes("  " + b64 + "\n")); // tolerate whitespace
  assert.equal(new TextDecoder().decode(vfs.get("a.txt")), "hello bundle");
});

test("parseZip rejects a non-zip buffer", async () => {
  await assert.rejects(() => parseZip(enc.encode("not a zip at all")), /no EOCD/);
});

test("parseZip caps on ACTUAL output — a LYING declared size can't run away", async () => {
  // The review's exact PoC: declare uncomp=1 byte but actually inflate to 1 MB.
  // The host fix measures actual output; the loader must too. With a 64 KB cap it
  // aborts mid-stream regardless of the (forged) declared size.
  const bomb = makeZip([{ name: "bomb", data: new Uint8Array(1024 * 1024), declUncomp: 1 }]);
  await assert.rejects(
    () => parseZip(bomb, { maxTotalBytes: 64 * 1024, maxEntryBytes: 64 * 1024 }),
    /zip-bomb guard|inflated past the cap/,
  );
});

test("parseZip caps the RUNNING total across many tiny-declared entries (N-entry bomb)", async () => {
  // 8 entries, each declaring uncomp=1 (declared total = 8 bytes) but each actually
  // ~256 KB → 2 MB real. A 512 KB total cap must abort before materializing it all,
  // proving the running cap is on ACTUAL bytes, not the declared sum.
  const entries = Array.from({ length: 8 }, (_, i) => ({
    name: `e${i}.bin`, data: new Uint8Array(256 * 1024), declUncomp: 1,
  }));
  await assert.rejects(
    () => parseZip(makeZip(entries), { maxTotalBytes: 512 * 1024, maxEntryBytes: 512 * 1024 }),
    /zip-bomb guard|inflated past the cap/,
  );
});

test("parseZip allows an honest entry under the cap (no false positive)", async () => {
  const vfs = await parseZip(makeZip([{ name: "ok.bin", data: new Uint8Array(100 * 1024) }]));
  assert.equal(vfs.get("ok.bin").length, 100 * 1024);
});
