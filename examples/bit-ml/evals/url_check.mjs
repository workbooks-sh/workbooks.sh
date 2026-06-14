// URL-liveness gate — the hard half of the desk fabrication trap (wb-wc0.6).
//
// A fabricated citation's tell is a URL that does not resolve. A judge MODEL can
// be fooled by a plausible-looking link (right domain shape, real-sounding slug);
// a real network fetch cannot. So the eval harness fetch-checks every URL a desk
// or research pass emits — a 404 / dead host / invented domain is a fabrication
// and hard-fails the stage, no matter how confident the judge is.
//
// Zero deps (Node 18+ global fetch). Bounded per-URL so a hung host can't stall
// the suite (same discipline as the runtime's provisioning fetches, wb-1ffa).

const PER_URL_TIMEOUT_MS = 15_000;

// Pull bare http(s) URLs out of org/markdown text. Strips the trailing
// punctuation org/markdown commonly glues on (".", ")", "]", ",", etc.) and the
// closing paren/bracket of a [[url]] / (url) wrapper, then dedups.
export function extractUrls(text) {
  const raw = String(text || "").match(/https?:\/\/[^\s<>()[\]"'`]+/g) ?? [];
  const cleaned = raw.map((u) => u.replace(/[.,;:!?)\]}>]+$/, ""));
  return [...new Set(cleaned)];
}

// Does this URL resolve to real content? HEAD is cheapest; hosts that reject it
// (405/501) get a 1-byte ranged GET. Any network failure (DNS miss on an invented
// domain, timeout, refused) counts as NOT live — which is exactly the signal a
// fabricated citation gives off.
export async function urlIsLive(url, { timeoutMs = PER_URL_TIMEOUT_MS, fetchImpl = fetch } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    let res = await fetchImpl(url, { method: "HEAD", redirect: "follow", signal: controller.signal });
    if (res.status === 405 || res.status === 501) {
      res = await fetchImpl(url, {
        method: "GET",
        redirect: "follow",
        headers: { Range: "bytes=0-0" },
        signal: controller.signal,
      });
    }
    return res.status >= 200 && res.status < 400;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

// Check every URL in a body. Returns { urls, dead } — `dead` is the fabrication
// evidence the harness fails on. Checks run concurrently (each is bounded).
export async function checkUrlsLive(text, opts = {}) {
  const urls = extractUrls(text);
  const verdicts = await Promise.all(
    urls.map(async (url) => ({ url, live: await urlIsLive(url, opts) })),
  );
  return { urls, dead: verdicts.filter((v) => !v.live).map((v) => v.url) };
}
