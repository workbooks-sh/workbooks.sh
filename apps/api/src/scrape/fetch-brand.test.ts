// Unit tests for fetchBrand() — tiered fetch primitive.
//
// Run with: bun test apps/api/src/scrape/fetch-brand.test.ts
//
// All network calls are mocked via globalThis.fetch intercepts.
// The BROWSER binding and vendor API keys are provided via a fake Bindings env.

import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import type { Bindings } from "../env.js";
import { fetchBrand } from "./fetch-brand.js";

// ── Fake env ──────────────────────────────────────────────────────────────────

function makeEnv(overrides: Partial<Bindings> = {}): Bindings {
  return {
    ENV_NAME: "test",
    DB: undefined as unknown as D1Database,
    ASSETS: undefined as unknown as R2Bucket,
    // BROWSER is intentionally missing unless overridden — tests the
    // "browser_binding_missing" skip path.
    BROWSER: undefined as unknown as Fetcher,
    CONTEXT_DEV_API_KEY: "test-context-key",
    FIRECRAWL_API_KEY: "test-firecrawl-key",
    ...overrides,
  };
}

// ── Mock fetch helper ─────────────────────────────────────────────────────────

type MockHandler = (url: string | URL | Request, init?: RequestInit) => Promise<Response>;

let originalFetch: typeof fetch;

function mockFetch(handler: MockHandler) {
  globalThis.fetch = handler as typeof fetch;
}

function restoreFetch() {
  globalThis.fetch = originalFetch;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("fetchBrand — Tier 1: direct", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("returns body on 200", async () => {
    mockFetch(async () =>
      new Response("<html>hello</html>", { status: 200, headers: { "content-type": "text/html" } }),
    );

    const result = await fetchBrand(makeEnv(), "https://stripe.com", { skipTiers: ["cf-browser", "context-dev", "firecrawl"] });
    expect(result.ok).toBe(true);
    expect(result.source).toBe("direct");
    expect(result.status).toBe(200);
    expect(result.body).toContain("hello");
    expect(result.attempts).toHaveLength(1);
    expect(result.attempts[0]?.tier).toBe("direct");
    expect(result.attempts[0]?.error).toBeUndefined();
  });

  it("skips to next tier on 403", async () => {
    let callCount = 0;
    mockFetch(async (url) => {
      callCount++;
      const urlStr = url.toString();
      if (urlStr === "https://kitchenaid.com") {
        return new Response("Forbidden", { status: 403 });
      }
      // context-dev scrape call
      if (urlStr.startsWith("https://api.context.dev/v1/scrape/html")) {
        return new Response(JSON.stringify({ html: "<html>kitchenaid</html>" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response("not found", { status: 404 });
    });

    const result = await fetchBrand(makeEnv(), "https://kitchenaid.com", {
      skipTiers: ["cf-browser", "firecrawl"],
    });
    expect(result.ok).toBe(true);
    expect(result.source).toBe("context-dev");
    expect(result.attempts.length).toBeGreaterThanOrEqual(2);

    const directAttempt = result.attempts.find((a) => a.tier === "direct");
    expect(directAttempt?.status).toBe(403);
    expect(directAttempt?.error).toContain("waf_blocked");

    const ctxAttempt = result.attempts.find((a) => a.tier === "context-dev");
    expect(ctxAttempt?.status).toBe(200);
  });

  it("skips to next tier on 429", async () => {
    mockFetch(async (url) => {
      const urlStr = url.toString();
      if (urlStr === "https://example.com") {
        return new Response("Rate limited", { status: 429 });
      }
      if (urlStr === "https://api.firecrawl.dev/v1/scrape") {
        return new Response(
          JSON.stringify({ success: true, data: { html: "<html>ok</html>" } }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      return new Response("nope", { status: 500 });
    });

    const result = await fetchBrand(makeEnv(), "https://example.com", {
      skipTiers: ["cf-browser", "context-dev"],
    });
    expect(result.ok).toBe(true);
    expect(result.source).toBe("firecrawl");

    const directAttempt = result.attempts.find((a) => a.tier === "direct");
    expect(directAttempt?.error).toContain("waf_blocked:429");
  });

  it("skips to next tier on 503", async () => {
    let callCount = 0;
    mockFetch(async () => {
      callCount++;
      if (callCount === 1) return new Response("Service Unavailable", { status: 503 });
      return new Response(JSON.stringify({ html: "<html>ok</html>" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });

    const result = await fetchBrand(makeEnv(), "https://example.com", {
      skipTiers: ["cf-browser", "firecrawl"],
    });
    expect(result.source).toBe("context-dev");
    const directAttempt = result.attempts.find((a) => a.tier === "direct");
    expect(directAttempt?.error).toContain("waf_blocked:503");
  });
});

// ── Tier 2: cf-browser (mocked as missing binding) ───────────────────────────

describe("fetchBrand — Tier 2: cf-browser (binding absent)", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("records browser_binding_missing and falls through to context-dev", async () => {
    mockFetch(async (url) => {
      const urlStr = url.toString();
      if (urlStr === "https://waf.example.com") {
        return new Response("Forbidden", { status: 403 });
      }
      if (urlStr.startsWith("https://api.context.dev/v1/scrape/html")) {
        return new Response(JSON.stringify({ html: "<html>scraped content</html>" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response("nope", { status: 500 });
    });

    // env has no BROWSER binding
    const result = await fetchBrand(makeEnv(), "https://waf.example.com", {
      skipTiers: ["firecrawl"],
    });

    expect(result.ok).toBe(true);
    expect(result.source).toBe("context-dev");

    const browserAttempt = result.attempts.find((a) => a.tier === "cf-browser");
    expect(browserAttempt?.error).toBe("browser_binding_missing");
  });
});

// ── Tier 3: context-dev ──────────────────────────────────────────────────────

describe("fetchBrand — Tier 3: context-dev", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("returns body from context-dev on success", async () => {
    mockFetch(async (url) => {
      const urlStr = url.toString();
      if (urlStr.startsWith("https://api.context.dev/v1/scrape/html")) {
        return new Response(JSON.stringify({ html: "<html>context-dev content</html>" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response("blocked", { status: 403 });
    });

    const result = await fetchBrand(
      makeEnv(),
      "https://blocked.example.com",
      { skipTiers: ["cf-browser", "firecrawl"] },
    );

    expect(result.ok).toBe(true);
    expect(result.source).toBe("context-dev");
    expect(result.body).toContain("context-dev content");
  });

  it("skips when CONTEXT_DEV_API_KEY is missing", async () => {
    const calls: string[] = [];
    mockFetch(async (url) => {
      const urlStr = url.toString();
      calls.push(urlStr);
      if (urlStr === "https://api.firecrawl.dev/v1/scrape") {
        return new Response(
          JSON.stringify({ success: true, data: { html: "<html>firecrawl ok</html>" } }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      return new Response("blocked", { status: 403 });
    });

    const env = makeEnv({ CONTEXT_DEV_API_KEY: undefined });
    const result = await fetchBrand(env, "https://blocked.example.com", {
      skipTiers: ["cf-browser"],
    });

    expect(result.ok).toBe(true);
    expect(result.source).toBe("firecrawl");
    const ctxAttempt = result.attempts.find((a) => a.tier === "context-dev");
    expect(ctxAttempt?.error).toBe("context_dev_key_missing");
  });
});

// ── Tier 4: firecrawl ────────────────────────────────────────────────────────

describe("fetchBrand — Tier 4: firecrawl", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("returns body from firecrawl as last resort", async () => {
    mockFetch(async (url) => {
      const urlStr = url.toString();
      if (urlStr === "https://api.firecrawl.dev/v1/scrape") {
        return new Response(
          JSON.stringify({ success: true, data: { markdown: "# Hello from Firecrawl" } }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      return new Response("blocked", { status: 403 });
    });

    const result = await fetchBrand(makeEnv(), "https://heavy-waf.example.com", {
      skipTiers: ["cf-browser", "context-dev"],
    });

    expect(result.ok).toBe(true);
    expect(result.source).toBe("firecrawl");
    expect(result.body).toContain("Hello from Firecrawl");
  });

  it("skips when FIRECRAWL_API_KEY is missing", async () => {
    mockFetch(async () => new Response("blocked", { status: 403 }));

    const env = makeEnv({ CONTEXT_DEV_API_KEY: undefined, FIRECRAWL_API_KEY: undefined });
    const result = await fetchBrand(env, "https://blocked.example.com", {
      skipTiers: ["cf-browser"],
    });

    expect(result.ok).toBe(false);
    const fcAttempt = result.attempts.find((a) => a.tier === "firecrawl");
    expect(fcAttempt?.error).toBe("firecrawl_key_missing");
  });
});

// ── All tiers fail ────────────────────────────────────────────────────────────

describe("fetchBrand — all tiers fail", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("returns ok=false with full attempts array for a nonexistent domain", async () => {
    mockFetch(async () => new Response("blocked", { status: 403 }));

    const env = makeEnv({ CONTEXT_DEV_API_KEY: undefined, FIRECRAWL_API_KEY: undefined });
    const result = await fetchBrand(env, "https://this-domain-does-not-exist-xyz-99.invalid", {
      skipTiers: ["cf-browser"],
    });

    expect(result.ok).toBe(false);
    // At minimum direct was attempted
    expect(result.attempts.length).toBeGreaterThanOrEqual(1);
    expect(result.attempts.every((a) => !!a.tier)).toBe(true);
  });
});

// ── skipTiers option ─────────────────────────────────────────────────────────

describe("fetchBrand — skipTiers option", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("never calls a skipped tier", async () => {
    const calledTiers: string[] = [];
    mockFetch(async (url) => {
      const urlStr = url.toString();
      if (urlStr.startsWith("https://api.context.dev/v1/scrape/html")) {
        calledTiers.push("context-dev");
      } else if (urlStr === "https://api.firecrawl.dev/v1/scrape") {
        calledTiers.push("firecrawl");
      } else {
        calledTiers.push("direct");
      }
      return new Response("<html>ok</html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      });
    });

    await fetchBrand(makeEnv(), "https://weliveconscious.com", {
      skipTiers: ["cf-browser", "context-dev", "firecrawl"],
    });

    expect(calledTiers).not.toContain("context-dev");
    expect(calledTiers).not.toContain("firecrawl");
  });
});

// ── attempts[] shape ─────────────────────────────────────────────────────────

describe("fetchBrand — attempts shape", () => {
  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });
  afterEach(() => restoreFetch());

  it("each attempt has tier, status, ms fields", async () => {
    mockFetch(async (url) => {
      const urlStr = url.toString();
      if (urlStr === "https://example.com") return new Response("blocked", { status: 403 });
      if (urlStr.startsWith("https://api.context.dev/v1/scrape/html")) {
        return new Response(JSON.stringify({ html: "<html>ok</html>" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response("err", { status: 500 });
    });

    const result = await fetchBrand(makeEnv(), "https://example.com", {
      skipTiers: ["cf-browser", "firecrawl"],
    });

    for (const attempt of result.attempts) {
      expect(typeof attempt.tier).toBe("string");
      expect(typeof attempt.status).toBe("number");
      expect(typeof attempt.ms).toBe("number");
      expect(attempt.ms).toBeGreaterThanOrEqual(0);
    }
  });

  it("total fetch_ms is non-negative", async () => {
    mockFetch(async () =>
      new Response("<html>ok</html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      }),
    );

    const result = await fetchBrand(makeEnv(), "https://stripe.com", {
      skipTiers: ["cf-browser", "context-dev", "firecrawl"],
    });

    expect(result.fetch_ms).toBeGreaterThanOrEqual(0);
  });
});
