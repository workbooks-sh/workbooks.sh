/**
 * TS-side workbook-manifest verifier.
 *
 * TODO(packaging): this file is currently duplicated between
 *   apps/desktop/src/lib/network/verify.ts
 *   apps/viewer/src/lib/verify.ts
 * When a third consumer needs it, extract to packages/network-ui/
 * (or packages/verify-ts/) and depend on it from both. Keeping the
 * copy until then because (a) the public API surface is small, (b)
 * there's exactly one cross-impl contract test (the Elixir
 * @rust_xverify suite), and (c) a shared package would need its own
 * tsconfig + publish dance for marginal benefit today.
 *
 * Mirrors `packages/workbooks-manifest` (Rust) — same manifest shape,
 * same three checks, same did:key encoding. Lives here so the
 * Viewer can verify a workbook `.html` without shelling out to the
 * Rust CLI: WebCrypto gives us Ed25519 + SHA-256 + base64 natively.
 *
 * Cross-impl contract — when the Rust crate's canonical_json or
 * manifest schema changes, this file MUST change in lockstep. See
 * the `CROSS-IMPL CONTRACT` notes in:
 *   packages/workbooks-manifest/src/embed.rs
 *   packages/oql/elixir/oql-agent/lib/oql_agent/network/manifest.ex
 *
 * Three checks (any fail → FAIL):
 *   1. Ed25519 signature over canonical_json(manifest) matches the
 *      embedded pubkey
 *   2. did_key(embedded pubkey) === manifest.issuer_did
 *   3. sha256(html_without_manifest) === manifest.asset_sha256
 */

// ── Manifest schema ─────────────────────────────────────────────────

/** Schema versions emitted by signers. Verifier accepts BOTH. v2 adds
 *  an OPTIONAL `claim_chain` field; an empty chain canonicalises
 *  byte-identical to v1 (matches the Rust `skip_serializing_if` and
 *  Elixir conditional emit). */
export const MANIFEST_VERSION = "v1";
const ACCEPTED_VERSIONS = ["v1", "v2"];

export type AssertionType =
  | "c2pa.action.published"
  | "c2pa.action.updated"
  | "c2pa.action.forked"
  | "c2pa.workbook.title"
  | "c2pa.workbook.role";

export interface ClaimRecord {
  issuer_did: string;
  claim_generator: string;
  issued_at: string;
  asset_sha256: string;
  pubkey_b64: string;
  signature_b64: string;
  /** Hash of parent claim's canonical JSON; null for genesis. */
  parent_claim_sha256: string | null;
}

export interface Manifest {
  version: string;
  issuer_did: string;
  claim_generator: string;
  issued_at: string;
  asset_sha256: string;
  assertions: { type: AssertionType; [k: string]: unknown }[];
  /** Prior claims (oldest first). Empty/absent in v1 envelopes. */
  claim_chain?: ClaimRecord[];
}

export interface SignedEnvelope {
  manifest: Manifest;
  pubkey_b64: string;
  signature_b64: string;
}

export interface VerifyReport {
  ok: true;
  issuer_did: string;
  issued_at: string;
  claim_generator: string;
  asset_sha256: string;
  assertions: Manifest["assertions"];
  /** Verified chain links (oldest first). Empty for genesis envelopes. */
  claim_chain: ClaimRecord[];
}

export type VerifyFailReason =
  | "no_manifest"
  | "unsupported_version"
  | "envelope_malformed"
  | "envelope_b64"
  | "pubkey_length"
  | "pubkey_invalid"
  | "signature_length"
  | "signature_mismatch"
  | "issuer_mismatch"
  | "asset_modified"
  | "chain_signature_mismatch"
  | "chain_issuer_mismatch"
  | "chain_broken"
  | "chain_genesis_has_parent"
  | "chain_non_genesis_missing_parent"
  | "webcrypto_unavailable";

export interface VerifyFail {
  ok: false;
  reason: VerifyFailReason;
  detail?: string;
}

// ── HTML embed (mirrors Rust + Elixir tag constants) ────────────────

// CROSS-IMPL CONTRACT: this tag MUST stay byte-for-byte identical to
// packages/workbooks-manifest/src/embed.rs::MANIFEST_TAG_OPEN AND
// packages/oql/elixir/oql-agent/lib/oql_agent/network/manifest.ex::@tag_open
const TAG_OPEN =
  '<script type="application/workbooks-c2pa+json" id="wb-c2pa-manifest">';
const TAG_CLOSE = "</script>";

/** Split HTML into (asset-without-manifest, manifest-b64-if-present).
 *  Normalizes to exactly one trailing newline to match the Rust /
 *  Elixir embed.split contract. */
export function split(html: string): { stripped: string; manifest_b64: string | null } {
  const openIdx = html.indexOf(TAG_OPEN);
  if (openIdx === -1) {
    return { stripped: normalizeTrailing(html), manifest_b64: null };
  }
  const afterOpen = openIdx + TAG_OPEN.length;
  const closeRel = html.slice(afterOpen).indexOf(TAG_CLOSE);
  if (closeRel === -1) {
    return { stripped: normalizeTrailing(html), manifest_b64: null };
  }
  const closeIdx = afterOpen + closeRel;
  const endIdx = closeIdx + TAG_CLOSE.length;
  const manifest_b64 = html.slice(afterOpen, closeIdx).trim();
  let trailing = html.slice(endIdx);
  if (trailing.startsWith("\n")) trailing = trailing.slice(1);
  const stripped = normalizeTrailing(html.slice(0, openIdx) + trailing);
  return { stripped, manifest_b64 };
}

function normalizeTrailing(html: string): string {
  return html.replace(/\n+$/, "") + "\n";
}

// ── did:key derivation (Ed25519 multikey) ───────────────────────────

const ED25519_MULTICODEC = new Uint8Array([0xed, 0x01]);
const B58_ALPHABET =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/** Encode bytes as base58btc (Bitcoin alphabet). */
function base58Encode(bytes: Uint8Array): string {
  if (bytes.length === 0) return "";
  let zeros = 0;
  while (zeros < bytes.length && bytes[zeros] === 0) zeros++;

  const digits: number[] = [];
  for (let i = zeros; i < bytes.length; i++) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j++) {
      carry += digits[j] << 8;
      digits[j] = carry % 58;
      carry = Math.floor(carry / 58);
    }
    while (carry > 0) {
      digits.push(carry % 58);
      carry = Math.floor(carry / 58);
    }
  }
  let out = "1".repeat(zeros);
  for (let i = digits.length - 1; i >= 0; i--) out += B58_ALPHABET[digits[i]];
  return out;
}

export function didKeyFromEd25519(pubkey: Uint8Array): string {
  if (pubkey.length !== 32) throw new Error("ed25519 pubkey must be 32 bytes");
  const multikey = new Uint8Array(2 + 32);
  multikey.set(ED25519_MULTICODEC, 0);
  multikey.set(pubkey, 2);
  return "did:key:z" + base58Encode(multikey);
}

// ── Canonical JSON (lock-step with Rust serde + Elixir hand-roll) ───

/** Canonicalize a manifest into the EXACT byte sequence the Rust
 *  serde_json + Elixir Manifest.canonical_json produce. Field order:
 *  version, issuer_did, claim_generator, issued_at, asset_sha256,
 *  assertions. Per assertion: type first, then variant-specific keys
 *  in declaration order. */
export function canonicalJson(m: Manifest): string {
  const parts: string[] = [
    "{",
    `"version":${JSON.stringify(m.version)}`,
    `,"issuer_did":${JSON.stringify(m.issuer_did)}`,
    `,"claim_generator":${JSON.stringify(m.claim_generator)}`,
    `,"issued_at":${JSON.stringify(m.issued_at)}`,
    `,"asset_sha256":${JSON.stringify(m.asset_sha256)}`,
    `,"assertions":[`,
  ];
  parts.push(m.assertions.map(canonicalAssertion).join(","));
  // claim_chain is omitted when empty/absent (mirrors Rust's
  // skip_serializing_if and Elixir's conditional emit) so v2-with-empty
  // chain byte-matches v1.
  const chain = m.claim_chain ?? [];
  if (chain.length === 0) {
    parts.push("]}");
  } else {
    parts.push("]");
    parts.push(`,"claim_chain":[`);
    parts.push(chain.map(canonicalClaimFull).join(","));
    parts.push("]}");
  }
  return parts.join("");
}

/** Canonical bytes-to-sign for a single chain link — excludes
 *  `signature_b64`. Mirrors Rust's `canonical_claim_to_sign` and
 *  Elixir's `canonical_claim_to_sign/1`. */
export function canonicalClaimToSign(rec: ClaimRecord): string {
  return (
    `{"issuer_did":${JSON.stringify(rec.issuer_did)}` +
    `,"claim_generator":${JSON.stringify(rec.claim_generator)}` +
    `,"issued_at":${JSON.stringify(rec.issued_at)}` +
    `,"asset_sha256":${JSON.stringify(rec.asset_sha256)}` +
    `,"pubkey_b64":${JSON.stringify(rec.pubkey_b64)}` +
    `,"parent_claim_sha256":${rec.parent_claim_sha256 === null ? "null" : JSON.stringify(rec.parent_claim_sha256)}}`
  );
}

/** Canonical bytes of a fully-signed claim record. Used to compute
 *  the `parent_claim_sha256` the NEXT link references. */
export function canonicalClaimFull(rec: ClaimRecord): string {
  return (
    `{"issuer_did":${JSON.stringify(rec.issuer_did)}` +
    `,"claim_generator":${JSON.stringify(rec.claim_generator)}` +
    `,"issued_at":${JSON.stringify(rec.issued_at)}` +
    `,"asset_sha256":${JSON.stringify(rec.asset_sha256)}` +
    `,"pubkey_b64":${JSON.stringify(rec.pubkey_b64)}` +
    `,"signature_b64":${JSON.stringify(rec.signature_b64)}` +
    `,"parent_claim_sha256":${rec.parent_claim_sha256 === null ? "null" : JSON.stringify(rec.parent_claim_sha256)}}`
  );
}

function canonicalAssertion(a: Manifest["assertions"][number]): string {
  switch (a.type) {
    case "c2pa.action.published":
      return (
        `{"type":"c2pa.action.published","actor":${JSON.stringify(a.actor)}` +
        `,"network":${JSON.stringify(a.network)}}`
      );
    case "c2pa.action.updated":
      return (
        `{"type":"c2pa.action.updated","actor":${JSON.stringify(a.actor)}` +
        `,"parent_sha256":${JSON.stringify(a.parent_sha256)}}`
      );
    case "c2pa.action.forked":
      return (
        `{"type":"c2pa.action.forked","actor":${JSON.stringify(a.actor)}` +
        `,"upstream_did":${JSON.stringify(a.upstream_did)}` +
        `,"upstream_rid":${JSON.stringify(a.upstream_rid)}}`
      );
    case "c2pa.workbook.title":
      return `{"type":"c2pa.workbook.title","value":${JSON.stringify(a.value)}}`;
    case "c2pa.workbook.role":
      return `{"type":"c2pa.workbook.role","value":${JSON.stringify(a.value)}}`;
  }
}

// ── Verify ─────────────────────────────────────────────────────────

/** Verify a signed workbook `.html`. Returns a typed report — never throws. */
export async function verifyHtml(html: string): Promise<VerifyReport | VerifyFail> {
  if (typeof crypto === "undefined" || !crypto.subtle) {
    return { ok: false, reason: "webcrypto_unavailable" };
  }

  const { stripped, manifest_b64 } = split(html);
  if (manifest_b64 === null) return { ok: false, reason: "no_manifest" };

  let envelope: SignedEnvelope;
  try {
    const envelopeJson = atob(manifest_b64);
    envelope = JSON.parse(envelopeJson);
  } catch (e) {
    return {
      ok: false,
      reason: "envelope_malformed",
      detail: e instanceof Error ? e.message : String(e),
    };
  }

  if (!ACCEPTED_VERSIONS.includes(envelope.manifest.version)) {
    return {
      ok: false,
      reason: "unsupported_version",
      detail: envelope.manifest.version,
    };
  }

  // Decode pubkey + signature
  let pubkeyBytes: Uint8Array;
  let sigBytes: Uint8Array;
  try {
    pubkeyBytes = b64ToBytes(envelope.pubkey_b64);
    sigBytes = b64ToBytes(envelope.signature_b64);
  } catch {
    return { ok: false, reason: "envelope_b64" };
  }
  if (pubkeyBytes.length !== 32) return { ok: false, reason: "pubkey_length" };
  if (sigBytes.length !== 64) return { ok: false, reason: "signature_length" };

  // 1. Signature
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "raw",
      pubkeyBytes as BufferSource,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
  } catch {
    return { ok: false, reason: "pubkey_invalid" };
  }

  const manifestBytes = new TextEncoder().encode(canonicalJson(envelope.manifest));
  let sigOk = false;
  try {
    // Cast to BufferSource — TS's lib.dom types want ArrayBufferView<ArrayBuffer>
    // but `new Uint8Array(…)` in newer TS infers ArrayBufferLike. The actual
    // backing buffer here is ALWAYS ArrayBuffer (TextEncoder, fresh Uint8Array,
    // b64ToBytes); the cast is type-safe.
    sigOk = await crypto.subtle.verify(
      "Ed25519",
      key,
      sigBytes as BufferSource,
      manifestBytes as BufferSource,
    );
  } catch {
    return { ok: false, reason: "signature_mismatch" };
  }
  if (!sigOk) return { ok: false, reason: "signature_mismatch" };

  // 2. DID derivation
  const derivedDid = didKeyFromEd25519(pubkeyBytes);
  if (derivedDid !== envelope.manifest.issuer_did) {
    return {
      ok: false,
      reason: "issuer_mismatch",
      detail: `manifest=${envelope.manifest.issuer_did} derived=${derivedDid}`,
    };
  }

  // 3. Asset hash
  const strippedBytes = new TextEncoder().encode(stripped);
  const hashBuf = await crypto.subtle.digest(
    "SHA-256",
    strippedBytes as BufferSource,
  );
  const actual = bytesToHex(new Uint8Array(hashBuf));
  if (actual !== envelope.manifest.asset_sha256) {
    return {
      ok: false,
      reason: "asset_modified",
      detail: `expected=${envelope.manifest.asset_sha256} actual=${actual}`,
    };
  }

  // 4. Claim chain (v2). Each link verifies independently + chains by
  //    parent_claim_sha256 to the prior link's canonical-full hash.
  const chain = envelope.manifest.claim_chain ?? [];
  let prevLinkHash: string | null = null;
  for (let i = 0; i < chain.length; i++) {
    const link = chain[i];
    const linkResult = await verifyChainLink(i, link);
    if (linkResult) return linkResult;

    if (i === 0 && link.parent_claim_sha256 !== null) {
      return { ok: false, reason: "chain_genesis_has_parent", detail: `index=${i}` };
    }
    if (i > 0 && link.parent_claim_sha256 === null) {
      return { ok: false, reason: "chain_non_genesis_missing_parent", detail: `index=${i}` };
    }
    if (i > 0 && link.parent_claim_sha256 !== prevLinkHash) {
      return {
        ok: false,
        reason: "chain_broken",
        detail: `index=${i} claimed=${link.parent_claim_sha256} computed=${prevLinkHash}`,
      };
    }
    const fullBytes = new TextEncoder().encode(canonicalClaimFull(link));
    const hb = await crypto.subtle.digest("SHA-256", fullBytes as BufferSource);
    prevLinkHash = bytesToHex(new Uint8Array(hb));
  }

  return {
    ok: true,
    issuer_did: envelope.manifest.issuer_did,
    issued_at: envelope.manifest.issued_at,
    claim_generator: envelope.manifest.claim_generator,
    asset_sha256: envelope.manifest.asset_sha256,
    assertions: envelope.manifest.assertions,
    claim_chain: chain,
  };
}

/** Verify one chain link's own signature + DID derivation. Returns
 *  null on success, or a typed VerifyFail to short-circuit. */
async function verifyChainLink(
  index: number,
  link: ClaimRecord,
): Promise<VerifyFail | null> {
  let pubkey: Uint8Array;
  let sig: Uint8Array;
  try {
    pubkey = b64ToBytes(link.pubkey_b64);
    sig = b64ToBytes(link.signature_b64);
  } catch {
    return { ok: false, reason: "envelope_b64", detail: `chain link ${index}` };
  }
  if (pubkey.length !== 32) {
    return { ok: false, reason: "pubkey_length", detail: `chain link ${index}` };
  }
  if (sig.length !== 64) {
    return { ok: false, reason: "signature_length", detail: `chain link ${index}` };
  }

  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "raw",
      pubkey as BufferSource,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
  } catch {
    return { ok: false, reason: "pubkey_invalid", detail: `chain link ${index}` };
  }

  const toSign = new TextEncoder().encode(canonicalClaimToSign(link));
  let sigOk = false;
  try {
    sigOk = await crypto.subtle.verify(
      "Ed25519",
      key,
      sig as BufferSource,
      toSign as BufferSource,
    );
  } catch {
    return { ok: false, reason: "chain_signature_mismatch", detail: `index=${index}` };
  }
  if (!sigOk) {
    return { ok: false, reason: "chain_signature_mismatch", detail: `index=${index}` };
  }

  const derived = didKeyFromEd25519(pubkey);
  if (derived !== link.issuer_did) {
    return {
      ok: false,
      reason: "chain_issuer_mismatch",
      detail: `index=${index} claimed=${link.issuer_did} derived=${derived}`,
    };
  }
  return null;
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  const HEX = "0123456789abcdef";
  let s = "";
  for (let i = 0; i < bytes.length; i++) {
    s += HEX[bytes[i] >> 4] + HEX[bytes[i] & 0x0f];
  }
  return s;
}
