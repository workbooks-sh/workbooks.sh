// Wire-format conformance tests for the Engine TenantToken minter.
//
// These pin the EXACT byte format the Elixir verifier expects
// (runtime/engine/lib/workbooks_runtime/api/tenant_token.ex). The Verify phase
// cross-checks a token minted here against that verifier; this file is the
// TS-side proof that we reproduce it.
//
// Run with: bun test apps/api/src/engine-client.test.ts

import { describe, expect, it } from "bun:test";
import {
  engineBearerHeader,
  mintTenantToken,
  TENANT_TOKEN_DEFAULT_TTL_SECONDS,
} from "./engine-client.js";

const KEY = "test-tenant-token-key-0123456789"; // >= 16 bytes

// ── Independent reference implementation of the wire format ──────────────────
// Re-derived from tenant_token.ex (NOT importing engine-client internals) so a
// regression in the minter cannot also corrupt the oracle.

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function referenceToken(tenant: string, exp: number, key: string): Promise<string> {
  const payload = `{"t":${JSON.stringify(tenant)},"exp":${exp}}`;
  const p64 = b64url(new TextEncoder().encode(payload));
  const ck = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", ck, new TextEncoder().encode(p64));
  const m64 = b64url(new Uint8Array(mac));
  return `${p64}.${m64}`;
}

/** Verify a token exactly like tenant_token.ex:52-69 (HMAC over p64, constant-ish compare). */
async function referenceVerify(token: string, key: string): Promise<string | null> {
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [p64, m64] = parts as [string, string];
  const ck = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = b64url(new Uint8Array(await crypto.subtle.sign("HMAC", ck, new TextEncoder().encode(p64))));
  if (expected !== m64) return null;
  const payload = JSON.parse(atob(p64.replace(/-/g, "+").replace(/_/g, "/"))) as {
    t: string;
    exp: number;
  };
  if (payload.exp <= Math.floor(Date.now() / 1000)) return null;
  return payload.t;
}

describe("mintTenantToken — wire format matches tenant_token.ex", () => {
  it("produces token = base64url(payload) '.' base64url(mac)", async () => {
    const token = await mintTenantToken("alice", KEY, 900);
    const [p64, m64] = token.split(".") as [string, string];
    expect(token.split(".")).toHaveLength(2);
    // Unpadded base64url: only [A-Za-z0-9_-], never '=', '+', '/'.
    expect(p64).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(m64).toMatch(/^[A-Za-z0-9_-]+$/);
    // HMAC-SHA256 → 32 bytes → 43 unpadded base64url chars.
    expect(m64).toHaveLength(43);
  });

  it("payload is canonical: {\"t\":...,\"exp\":...} fixed order, no whitespace", async () => {
    const token = await mintTenantToken("alice", KEY, 900);
    const p64 = token.split(".")[0] as string;
    const payload = atob(p64.replace(/-/g, "+").replace(/_/g, "/"));
    expect(payload).toMatch(/^\{"t":"alice","exp":\d+\}$/);
    expect(payload).not.toContain(" ");
    // "t" must precede "exp".
    expect(payload.indexOf('"t"')).toBeLessThan(payload.indexOf('"exp"'));
  });

  it("byte-matches the independent reference for the same exp", async () => {
    const exp = Math.floor(Date.now() / 1000) + 900;
    const token = await mintTenantToken("acme-co", KEY, 900);
    const tokenExp = JSON.parse(
      atob((token.split(".")[0] as string).replace(/-/g, "+").replace(/_/g, "/")),
    ).exp as number;
    // Re-mint the reference with the token's own exp to avoid 1s skew.
    const ref = await referenceToken("acme-co", tokenExp, KEY);
    expect(token).toBe(ref);
    expect(Math.abs(tokenExp - exp)).toBeLessThanOrEqual(1);
  });

  it("MAC is over the base64url payload TEXT, not the raw payload bytes", async () => {
    // If we (wrongly) signed the raw payload bytes, this would differ.
    const exp = 2000000000;
    const payload = `{"t":"alice","exp":${exp}}`;
    const p64 = b64url(new TextEncoder().encode(payload));
    const ck = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(KEY),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const overText = b64url(
      new Uint8Array(await crypto.subtle.sign("HMAC", ck, new TextEncoder().encode(p64))),
    );
    const overRaw = b64url(
      new Uint8Array(await crypto.subtle.sign("HMAC", ck, new TextEncoder().encode(payload))),
    );
    expect(overText).not.toBe(overRaw); // the two strategies genuinely differ
    const token = await mintTenantToken("alice", KEY, 900); // current ts; just assert it verifies
    expect(await referenceVerify(token, KEY)).toBe("alice");
  });

  it("a freshly minted token verifies (round-trip)", async () => {
    const token = await mintTenantToken("tenant-7", KEY, 900);
    expect(await referenceVerify(token, KEY)).toBe("tenant-7");
  });

  it("token signed with the wrong key fails verify (T9)", async () => {
    const token = await mintTenantToken("alice", KEY, 900);
    expect(await referenceVerify(token, "another-wrong-key-9999999")).toBeNull();
  });

  it("default ttl is 900s (tenant_token.ex:26)", async () => {
    expect(TENANT_TOKEN_DEFAULT_TTL_SECONDS).toBe(900);
    const token = await mintTenantToken("alice", KEY);
    const exp = JSON.parse(
      atob((token.split(".")[0] as string).replace(/-/g, "+").replace(/_/g, "/")),
    ).exp as number;
    expect(exp - Math.floor(Date.now() / 1000)).toBeGreaterThan(890);
    expect(exp - Math.floor(Date.now() / 1000)).toBeLessThanOrEqual(900);
  });
});

describe("mintTenantToken — guards", () => {
  it("rejects a missing/short key (no_key, mirrors {:error, :no_key})", async () => {
    await expect(mintTenantToken("alice", undefined)).rejects.toThrow("no_key");
    await expect(mintTenantToken("alice", "tooshort")).rejects.toThrow("no_key");
  });

  it("rejects an invalid tenant slug (bad_tenant, T10)", async () => {
    await expect(mintTenantToken("../other", KEY)).rejects.toThrow("bad_tenant");
    await expect(mintTenantToken("Alice", KEY)).rejects.toThrow("bad_tenant"); // uppercase
    await expect(mintTenantToken("-leading", KEY)).rejects.toThrow("bad_tenant");
    await expect(mintTenantToken("", KEY)).rejects.toThrow("bad_tenant");
  });

  it("accepts a valid slug at the 128-char boundary", async () => {
    const slug = "a" + "b".repeat(127); // 128 chars total
    await expect(mintTenantToken(slug, KEY)).resolves.toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    await expect(mintTenantToken("a" + "b".repeat(128), KEY)).rejects.toThrow("bad_tenant"); // 129
  });
});

describe("engineBearerHeader", () => {
  it("returns a Bearer header whose token verifies for the tenant", async () => {
    const { Authorization } = await engineBearerHeader({ WB_TENANT_TOKEN_KEY: KEY }, "alice");
    expect(Authorization).toMatch(/^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    const token = Authorization.slice("Bearer ".length);
    expect(await referenceVerify(token, KEY)).toBe("alice");
  });

  it("propagates no_key when the env secret is absent", async () => {
    await expect(engineBearerHeader({ WB_TENANT_TOKEN_KEY: undefined }, "alice")).rejects.toThrow(
      "no_key",
    );
  });
});
