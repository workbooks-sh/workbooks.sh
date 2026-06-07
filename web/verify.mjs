// Browser/Node verifier for a signed Workbook artifact — the consumer side of
// the sharing rail. Zero deps: WebCrypto (Ed25519 + SHA-256) + atob, present in
// modern browsers and Node 20+. Verifies a workbook `.html` WITHOUT the runtime.
//
// Cross-impl contract with host/manifest.ex (Workbooks.Manifest):
//   * same tag, same did:key encoding, same canonical JSON (recursively
//     key-SORTED, compact), same two checks. If manifest.ex changes either the
//     canonical form or the tag, this MUST change in lockstep.
//
// Reduced from the archive's 483-line verifier: dropped claim-chain (v2), the
// base64 envelope indirection, and per-assertion hand-canonicalization — this
// scheme stores the manifest as raw JSON with an inline `signature`, and derives
// the pubkey from the self-certifying did:key, so none of that is needed.

const TAG_OPEN = '<script type="application/workbooks-c2pa+json" id="wb-c2pa-manifest">';
const TAG_CLOSE = "</script>";
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// did:key:z<base58(0xed01 || pub)> → the raw 32-byte Ed25519 public key.
function pubFromDid(did) {
  const enc = did.replace(/^did:key:z/, "");
  let n = 0n;
  for (const ch of enc) n = n * 58n + BigInt(B58.indexOf(ch));
  let hex = n.toString(16);
  if (hex.length % 2) hex = "0" + hex;
  let bytes = hex.match(/../g).map((h) => parseInt(h, 16));
  for (const ch of enc) { if (ch === "1") bytes.unshift(0); else break; }
  // strip the 2-byte multicodec prefix (0xed 0x01)
  return new Uint8Array(bytes.slice(2));
}

// Recursively key-sorted compact JSON — byte-identical to Elixir canonical/1.
function canonical(v) {
  if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
  if (v && typeof v === "object") {
    return "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canonical(v[k])).join(",") + "}";
  }
  return JSON.stringify(v);
}

const reEsc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
function strip(html) {
  return html.replace(new RegExp(reEsc(TAG_OPEN) + "[\\s\\S]*?" + reEsc(TAG_CLOSE), "g"), "");
}
function extract(html) {
  const m = html.match(new RegExp(reEsc(TAG_OPEN) + "([\\s\\S]*?)" + reEsc(TAG_CLOSE)));
  return m ? JSON.parse(m[1]) : null;
}

async function sha256Hex(str) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(str));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const b64ToBytes = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

// Verify a signed workbook HTML. Returns {valid, signature, asset_integrity,
// issuer_did, assertions} or {error}. Never throws.
export async function verifyHtml(html) {
  try {
    const full = extract(html);
    if (!full) return { error: "no manifest" };
    const { signature, ...manifest } = full;

    const pub = pubFromDid(manifest.issuer_did);
    const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
    const sigOk = !!signature && await crypto.subtle.verify(
      "Ed25519", key, b64ToBytes(signature), new TextEncoder().encode(canonical(manifest)));

    const hashOk = manifest.asset_sha256 === await sha256Hex(strip(html));
    return {
      valid: sigOk && hashOk, signature: sigOk, asset_integrity: hashOk,
      issuer_did: manifest.issuer_did, assertions: manifest.assertions || [],
    };
  } catch (e) {
    return { error: String(e && e.message || e) };
  }
}
