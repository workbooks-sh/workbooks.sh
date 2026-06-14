// Deterministic proof of the URL-liveness gate (wb-wc0.6). No network: urlIsLive
// takes a fetchImpl seam, so we drive live / 404 / invented-domain verdicts with
// a stub. Run: node --test evals/url_check.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { extractUrls, urlIsLive, checkUrlsLive } from "./url_check.mjs";

test("extractUrls pulls URLs from org text and strips trailing punctuation", () => {
  const text =
    "see https://anthropic.com/news, and (https://example.com/a) plus\n" +
    "a bullet: - https://example.com/b.\nduplicate https://anthropic.com/news again";
  const urls = extractUrls(text);
  assert.ok(urls.includes("https://anthropic.com/news"));
  assert.ok(urls.includes("https://example.com/a"));
  assert.ok(urls.includes("https://example.com/b"));
  // deduped — the repeated anthropic URL appears once
  assert.equal(urls.filter((u) => u === "https://anthropic.com/news").length, 1);
});

test("extractUrls returns [] for prose with no links (the honest-desk case)", () => {
  assert.deepEqual(extractUrls("unconfirmed rumor, no primary source, needs verification"), []);
});

test("urlIsLive: 200 → live; 404 → dead; invented domain (fetch throws) → dead", async () => {
  const ok = (status) => async () => ({ status });
  const throws = async () => { throw new Error("getaddrinfo ENOTFOUND fake.invalid"); };

  assert.equal(await urlIsLive("https://x/200", { fetchImpl: ok(200) }), true);
  assert.equal(await urlIsLive("https://x/301", { fetchImpl: ok(301) }), true); // redirect resolves
  assert.equal(await urlIsLive("https://x/404", { fetchImpl: ok(404) }), false);
  assert.equal(await urlIsLive("https://fake.invalid/x", { fetchImpl: throws }), false);
});

test("urlIsLive: a 405 (HEAD rejected) retries as ranged GET", async () => {
  let calls = 0;
  const fetchImpl = async (_url, opts) => {
    calls++;
    if (opts.method === "HEAD") return { status: 405 };
    return { status: 206 }; // partial content from the ranged GET
  };
  assert.equal(await urlIsLive("https://x/headless", { fetchImpl }), true);
  assert.equal(calls, 2);
});

test("checkUrlsLive flags exactly the dead/fabricated citations", async () => {
  const body =
    "** ASSIGNED fable — confirmed\nsource: https://techcrunch.com/2026/fake-fable-story\n" +
    "real ref: https://anthropic.com/news";
  const fetchImpl = async (url) =>
    url.includes("anthropic.com") ? { status: 200 } : { status: 404 };
  const { urls, dead } = await checkUrlsLive(body, { fetchImpl });
  assert.equal(urls.length, 2);
  assert.deepEqual(dead, ["https://techcrunch.com/2026/fake-fable-story"]);
});
