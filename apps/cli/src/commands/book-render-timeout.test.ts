// Test the render-slides client timeout (wb-kmt4): a hung render must fail loud
// + fast (its own budget) so it can't silently eat the 120s DONE_CHECK ceiling.

import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { fetchRenderSlides } from "./book.js";

const realFetch = globalThis.fetch;

// A fetch that never responds but rejects when its AbortSignal fires.
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

describe("fetchRenderSlides timeout", () => {
  beforeEach(() => {
    process.env.BRANDNANA_API_KEY = "test-key";
    process.env.WB_RENDER_TIMEOUT_MS = "50";
    globalThis.fetch = hangingFetch;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
    delete process.env.WB_RENDER_TIMEOUT_MS;
  });

  it("throws a loud 'timed out' error when the render hangs past the budget", async () => {
    let err: unknown;
    try {
      await fetchRenderSlides("https://api.brandnana.net/books/acme.html");
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toContain("timed out");
  });
});
