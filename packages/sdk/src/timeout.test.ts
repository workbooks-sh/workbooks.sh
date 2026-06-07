// Tests for the SDK client-side request timeouts (wb-syjo robustness audit).
// call() = total deadline; stream() = idle deadline (reset per chunk).
// Run: bun test src/timeout.test.ts (from packages/sdk/)

import { describe, expect, it } from "bun:test";
import { BrandnanaError, createBrandnanaClient } from "./index.js";

// A fetch that never responds but rejects when its AbortSignal fires (like real
// fetch). Used to prove the SDK's own deadline aborts a hung upstream.
const hangingFetch = ((_url: string | URL, init?: RequestInit) =>
  new Promise<Response>((_resolve, reject) => {
    const sig = init?.signal;
    if (sig) {
      if (sig.aborted) reject(sig.reason ?? new DOMException("aborted", "AbortError"));
      sig.addEventListener("abort", () =>
        reject(sig.reason ?? new DOMException("aborted", "AbortError")),
      );
    }
  })) as unknown as typeof globalThis.fetch;

describe("call() total timeout", () => {
  it("aborts a hung request and throws a loud BrandnanaError(408)", async () => {
    const client = createBrandnanaClient({ apiKey: "k", callTimeoutMs: 50, fetch: hangingFetch });
    let err: unknown;
    try {
      await client.design.tokens("acme.com"); // a call()-based verb
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(BrandnanaError);
    expect((err as BrandnanaError).status).toBe(408);
    expect((err as BrandnanaError).message).toContain("timed out");
  });

  it("does NOT time out a fast request", async () => {
    const okFetch = (async () =>
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as unknown as typeof globalThis.fetch;
    const client = createBrandnanaClient({ apiKey: "k", callTimeoutMs: 1000, fetch: okFetch });
    await expect(client.design.tokens("acme.com")).resolves.toBeDefined();
  });
});

describe("stream() idle timeout", () => {
  it("aborts a hung stream (no chunks) and throws BrandnanaError(408)", async () => {
    const client = createBrandnanaClient({ apiKey: "k", streamIdleMs: 50, fetch: hangingFetch });
    let err: unknown;
    try {
      for await (const _ of client.catalog.crawl({ domain: "acme.com", brandId: "b" })) {
        // never reached — the stream hangs, idle timer aborts it
      }
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(BrandnanaError);
    expect((err as BrandnanaError).status).toBe(408);
    expect((err as BrandnanaError).message).toContain("idle");
  });
});
