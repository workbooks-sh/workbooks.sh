// Client-side unseal for sealed-bundle entries (rzip, wb-v3w phase 2). A `.wbundle`
// seals gated entries as AES-256-GCM ciphertext; the runtime escrows the content
// key and releases it ONLY post-auth via POST /rcp/key/:key_id (Workbooks.Access).
// This module requests that key through the RCP client, then AES-256-GCM decrypts
// the envelope with WebCrypto (mirrors runtime/docs/sealed-bundle-demo.html).
//
// Envelope (matches Workbooks.Bundle.Sealed):  "wbseal1" || iv(12) || tag(16) || ct
// AAD is the key_id (bound into the GCM tag), so a relabelled entry fails to open.
// Any crypto/auth failure maps onto the existing RCP error vocabulary so the
// RouteGate → routing-outcome mapping (routing.ts) handles it uniformly.

import { RcpError } from "./types";
import type { RcpClient } from "./client";

const MAGIC = "wbseal1";
const MAGIC_LEN = MAGIC.length; // 7
const IV_LEN = 12;
const TAG_LEN = 16;

/** The runtime's key-release response (POST /rcp/key/:key_id). */
interface KeyRelease {
  key_id: string;
  algo: string;
  key: string; // base64 raw 32-byte AES-256 content key
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Copy bytes into a fresh, plain-ArrayBuffer-backed ArrayBuffer (a clean
 *  BufferSource for WebCrypto — avoids the SharedArrayBuffer union under strict TS). */
function buf(bytes: Uint8Array): ArrayBuffer {
  const out = new ArrayBuffer(bytes.length);
  new Uint8Array(out).set(bytes);
  return out;
}

function ascii(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
}

/** Is this byte array a sealed envelope? (cheap magic check) */
export function isSealed(bytes: Uint8Array): boolean {
  if (bytes.length < MAGIC_LEN) return false;
  for (let i = 0; i < MAGIC_LEN; i++) if (bytes[i] !== MAGIC.charCodeAt(i)) return false;
  return true;
}

/** Release a content key for `keyId` through the RCP client. Throws RcpError
 *  (unauthorized/forbidden/unavailable/...) which the gate maps to an outcome. */
export async function releaseKey(client: RcpClient, keyId: string): Promise<Uint8Array> {
  const rel = await client.request<KeyRelease>(`/rcp/key/${encodeURIComponent(keyId)}`, { method: "POST" });
  if (!rel?.key) throw new RcpError("forbidden", "key release returned no key");
  return b64ToBytes(rel.key);
}

/** AES-256-GCM decrypt a sealed envelope with a raw 32-byte content key. `keyId`
 *  is the AAD (must match what the packer sealed with). Returns the plaintext
 *  bytes. A wrong key / tamper / aad-mismatch throws RcpError("forbidden") — the
 *  same "the gate refused you the bytes" outcome a denied release produces. */
export async function openSealed(envelope: Uint8Array, keyBytes: Uint8Array, keyId: string): Promise<Uint8Array> {
  if (!isSealed(envelope)) throw new RcpError("bad_request", "not a sealed envelope");
  if (envelope.length < MAGIC_LEN + IV_LEN + TAG_LEN) throw new RcpError("bad_request", "sealed envelope truncated");

  const iv = envelope.slice(MAGIC_LEN, MAGIC_LEN + IV_LEN);
  const tag = envelope.slice(MAGIC_LEN + IV_LEN, MAGIC_LEN + IV_LEN + TAG_LEN);
  const ct = envelope.slice(MAGIC_LEN + IV_LEN + TAG_LEN);
  // WebCrypto AES-GCM wants ciphertext || tag.
  const ctTag = new Uint8Array(ct.length + tag.length);
  ctTag.set(ct, 0);
  ctTag.set(tag, ct.length);

  try {
    // Copy into fresh ArrayBuffer-backed views so WebCrypto's BufferSource typing
    // is satisfied (a sliced view may be SharedArrayBuffer-backed under strict TS).
    const key = await crypto.subtle.importKey("raw", buf(keyBytes), { name: "AES-GCM" }, false, ["decrypt"]);
    const pt = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: buf(iv), additionalData: buf(ascii(keyId)), tagLength: 128 },
      key,
      buf(ctTag),
    );
    return new Uint8Array(pt);
  } catch {
    // GCM tag failure (wrong key, tampered ct, mismatched aad) — indistinguishable
    // by design. Surface as a refused-content outcome, never the raw error.
    throw new RcpError("forbidden", "sealed entry failed to open");
  }
}

/** Full path: release the key for `keyId` then decrypt `envelope`. The one call a
 *  loader makes after routing decides an entry is gated. Crypto/auth failures are
 *  already mapped onto RcpError → the RouteGate handles them. */
export async function unseal(client: RcpClient, envelope: Uint8Array, keyId: string): Promise<Uint8Array> {
  const key = await releaseKey(client, keyId);
  return openSealed(envelope, key, keyId);
}
