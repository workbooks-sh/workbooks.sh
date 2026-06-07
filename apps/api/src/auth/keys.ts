// API-key minting + validation. Keys are formatted as `adk_live_<random>`,
// stored hashed (sha256) in D1. The first 8 chars of the cleartext are
// kept in `prefix` so we can identify a key in listings without exposing
// it. Cleartext is returned to the user exactly once at creation.

export const KEY_PREFIX = "adk_live_";

const KEY_BODY_BYTES = 32;

export interface ApiKeyRow {
  id: string;
  user_id: string;
  hash: string;
  prefix: string;
  label: string | null;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
}

export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomToken(): string {
  const buf = new Uint8Array(KEY_BODY_BYTES);
  crypto.getRandomValues(buf);
  // base32-ish: avoid 0/O/I/1 confusion. 36 chars, biased — fine for entropy
  // at 32 bytes.
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnpqrstuvwxyz";
  let out = "";
  for (const b of buf) {
    out += alphabet[b % alphabet.length];
  }
  return out;
}

export interface MintedKey {
  cleartext: string;
  hash: string;
  prefix: string;
}

export async function mintKey(): Promise<MintedKey> {
  const cleartext = KEY_PREFIX + randomToken();
  const hash = await sha256Hex(cleartext);
  const prefix = cleartext.slice(0, KEY_PREFIX.length + 8);
  return { cleartext, hash, prefix };
}

export function extractBearer(authHeader: string | null | undefined): string | null {
  if (!authHeader) return null;
  const m = /^Bearer\s+(.+)$/i.exec(authHeader);
  return m ? (m[1]?.trim() ?? null) : null;
}
