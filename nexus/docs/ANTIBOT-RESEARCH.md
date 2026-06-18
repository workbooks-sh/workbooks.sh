# Anti-bot / "look like a real client" — what nexus can build itself

What nexus can do **in the Elixir fetch layer + in-wasm** to get *comparable* (not
perfect) real-site reach vs hosted browser services (Browserless / Kernel / Browser
Use cloud), **excluding** anything needing external egress (residential proxies, IP
rotation). Architecture constraint: pages are fetched host-side via `Nexus.Dock.fetch`
→ `Nexus.Compilers.Shared.http_get` (`:httpc`/`:inets`, Erlang `:ssl`), then rendered
in-wasm (Blitz + StarlingMonkey). No Chromium, no CDP.

Evidence below is from live tests run on this machine on 2026-06-18 (curl probes) plus
cited sources. Proven vs speculative is marked.

---

## (a) Why we get blocked

There are four independent gates. We currently fail the **easiest** one.

### 1. The Wikipedia case — DIAGNOSED: missing User-Agent header (HTTP layer, not TLS)

`Shared.http_get/1` builds the request as `req = {String.to_charlist(url), []}` — an
**empty header list**, so `:httpc` sends no `User-Agent` (or a bare Erlang default).
Wikimedia rejects that outright.

Live, reproduced exactly (`nexus/lib/compilers/shared.ex:43`):

| Request | Result |
|---|---|
| `curl -A ""` (empty UA, mimics our `:httpc`) | **403, 126 bytes** |
| `curl -H "User-Agent: "` (blank) | **403, 126 bytes** |
| `curl -A "<Chrome UA>"` (one header) | **200, 1,005,781 bytes** |
| `curl` default UA | **200, 1MB** |

That 126-byte 403 body **is** the "0 bytes / empty fetch" symptom. Wikimedia's policy
requires a descriptive UA ([User-Agent policy](https://meta.wikimedia.org/wiki/User-Agent_policy)).
**This is a header bug, fixable in one line.** TLS is not involved — curl's TLS stack
(OpenSSL, a non-browser JA3) sailed through; only the missing UA mattered.

### 2. TLS fingerprinting (JA3 / JA4) — the real ceiling, hits *hard* targets only

Cloudflare/Akamai/PerimeterX score the **TLS ClientHello before reading any HTTP
header**: cipher-suite order, extensions, GREASE, supported-groups, ALPN. This hashes
to a JA3/JA4. Erlang `:ssl` (here: ssl 11.5.1, TLS 1.2/1.3) builds a ClientHello whose
shape is **OpenSSL/Erlang-distinctive — nothing like BoringSSL/Chrome** — and a hard
WAF can drop it regardless of headers. Cloudflare "knows the exact JA3 for [a non-
browser] library; the block happens before any HTTP data is exchanged"
([capsolver](https://www.capsolver.com/blog/All/web-scraping-with-curl-cffi),
[webclaw](https://webclaw.io/blog/tls-fingerprint-vs-browser-cloudflare)).

Crucially, Erlang `:ssl` gives us **no API to reorder cipher suites/extensions or set
GREASE the way Chrome does** — `versions`/`ciphers`/`eccs` let you *restrict* sets, not
forge a byte-identical BoringSSL ClientHello. So we cannot mint a believable Chrome JA3
from `:ssl`. *(Proven by API surface; cited as the standard finding for all OpenSSL-
family stacks — Mint/Finch/Gun/`:httpc` all sit on Erlang `:ssl` and share this.)*

How bad is it in practice? Live probe with a good Chrome UA over curl's (non-browser)
TLS:

| Site (protection) | Result |
|---|---|
| cloudflare.com (Cloudflare) | **200** |
| news.ycombinator.com | 200 |
| amazon.com | 202 (served) |
| nowsecure.nl (CF managed challenge demo) | **200** |
| **g2.com (PerimeterX)** | **403** |

So baseline-Cloudflare and most normal sites pass on UA alone; only the **aggressive**
tier (PerimeterX/Akamai bot-manager, CF "managed challenge" on) needs true TLS
impersonation. Chrome 110+ also **randomizes extension order**, which broke JA3's
reliability and pushed detectors toward JA4 (sorts extensions, adds ALPN/SNI) — meaning
a *static* spoof is itself fragile ([scrapfly JA3/JA4](https://scrapfly.io/web-scraping-tools/ja3-fingerprint)).

### 3. HTTP-layer realism (besides UA)

A real Chrome sends a coherent bundle we don't: ordered `sec-ch-ua` client hints,
`Accept` / `Accept-Language` / `Accept-Encoding: gzip, deflate, br`, `Sec-Fetch-*`,
`Upgrade-Insecure-Requests`, a referer chain, plus **HTTP/2** with a specific
SETTINGS/WINDOW_UPDATE/pseudo-header order (the Akamai h2 fingerprint). `:httpc` is
**HTTP/1.1 only** — so we have no h2 fingerprint to get wrong, and live tests show
**HTTP/1.1 still passes baseline Cloudflare (200)**. h2 fingerprinting matters only at
the same hard tier as JA3. We also must handle `gzip`/`br` decompression, cookies
(challenge cookies like `cf_clearance`), and 3xx redirects (`:httpc autoredirect: true`
is on; good). Consistency is enforced: a Chrome UA with a non-Chrome JA3, or a Chrome
JA3 with a Firefox UA, "triggers immediate blocks"
([brightdata](https://brightdata.com/blog/web-data/web-scraping-with-curl-cffi)).

### 4. Behavioral / JS challenges (Blitz + StarlingMonkey territory)

CF/Akamai JS challenges probe `navigator.*`, `window.*`, `screen`, WebGL/canvas
fingerprints, and timing. We render in-wasm (Blitz layout + StarlingMonkey JS), **not a
real browser**, so most of these surfaces are absent or trivially detectable. We can
**shim a believable `navigator`/`screen`/`window`** to pass the *simplest* checks, but
WebGL/canvas/audio fingerprints and CF's full "managed challenge" need real GPU/Canvas
— **not passable in a JS-DOM**. CAPTCHA (Turnstile/reCAPTCHA/hCaptcha) is **not solvable
without a solver service** — state that honestly.

---

## (b) Ranked self-hostable capability adds (NO proxy/IP services)

Ranked by leverage ÷ effort. Each tagged pure-Elixir / in-wasm / host-brokered.

| # | Capability | Layer | Effort | Leverage | Unblocks |
|---|---|---|---|---|---|
| **1** | **UA + realistic header set** on `http_get` (Chrome UA, `Accept*`, `Accept-Encoding: gzip,br`, `Sec-Fetch-*`, `sec-ch-ua`) | pure-Elixir | **trivial (hours)** | **huge** | Wikipedia-class + the majority of normal sites |
| 2 | **gzip/br decompression** of responses (`:httpc` returns raw; add `:zlib` gunzip + a brotli decoder — brotli via the wasm lane or `Accept-Encoding: gzip` only) | pure-Elixir | low | high | sites that only gzip; avoids garbled bodies |
| 3 | **Cookie jar** across redirects/requests (store + replay `Set-Cookie`, incl. `cf_clearance`) | pure-Elixir | low-med | high | session/consent-gated sites, soft CF |
| 4 | **Referer + navigation chain** (set `Referer`, `Sec-Fetch-Site: same-origin` on sub-fetches) | pure-Elixir | low | med | sites checking nav context |
| 5 | **`navigator`/`screen`/`window` shim** in StarlingMonkey for in-wasm JS challenges | in-wasm | med | med (narrow) | trivial JS-probe challenges only |
| **6** | **TLS impersonation via a brokered native client** — ship **curl-impersonate / curl_cffi** (BoringSSL, real Chrome JA3+JA4+h2) as a host-side broker binary behind `Dock.fetch`, used as a fallback when `:httpc` gets 403/challenge | host-brokered | **med-high** | **high (hard tier)** | PerimeterX/Akamai/CF-managed sites that #1–4 can't |
| 7 | rustls-in-wasm with a Chrome profile (`rustls` + a uTLS-style ClientHello builder) | in-wasm | **high** | high but **maintenance-heavy** | same hard tier, no host binary — but rustls today has **no Chrome-profile ClientHello forgery**; you'd port uTLS logic. Speculative. |

Notes:
- Erlang `:ssl` **cannot** be tuned into a Chrome JA3 (no extension/GREASE control) — do
  **not** sink effort into option-tuning Mint/Finch/Gun for fingerprint; they share the
  same `:ssl` ClientHello. Switching clients buys h2 + ergonomics, **not** a better JA3.
- curl-impersonate is the **proven** path: it's the de-facto tool the whole scraping
  ecosystem uses to defeat CF/Akamai JA3+h2
  ([scrapfly](https://scrapfly.io/blog/posts/curl-impersonate-scrape-chrome-firefox-tls-http2-fingerprint),
  [curl_cffi](https://github.com/lexiforest/curl_cffi)). It's a single self-hosted
  binary — **no external egress**, fits our host-broker model. The only cost: it's a
  native binary on the host (not in-wasm), and needs periodic version bumps to track
  Chrome.

---

## (c) Single highest-leverage next step

**Add a realistic header set (Chrome UA + `Accept*` + `Accept-Encoding` + `Sec-Fetch-*`
+ `sec-ch-ua`) to `Nexus.Compilers.Shared.http_get/1` and `Nexus.Dock.fetch/1`.**

It's a one-function change, it **directly fixes the proven Wikipedia 403→200 case**, and
live data shows UA-alone already clears baseline Cloudflare, HN, Amazon, and the CF
challenge-demo site. This is ~90% of the real-world reach for "agentic computer-use +
scraping of mostly-normal sites," for hours of work. Everything else is the long tail.

Concretely, replace the empty header list:
```elixir
@chrome_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
           "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
headers = [
  {~c"user-agent", String.to_charlist(@chrome_ua)},
  {~c"accept", ~c"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
  {~c"accept-language", ~c"en-US,en;q=0.9"},
  {~c"accept-encoding", ~c"gzip"},
  {~c"sec-fetch-dest", ~c"document"}, {~c"sec-fetch-mode", ~c"navigate"},
  {~c"sec-fetch-site", ~c"none"}, {~c"upgrade-insecure-requests", ~c"1"}
]
req = {String.to_charlist(url), headers}
```
(plus a `:zlib` gunzip on the body when `content-encoding: gzip`). **Do this first.**

**Then (step 2, when a real hard-tier need shows up):** wire **curl-impersonate as a
brokered fallback** in `Dock.fetch` — try `:httpc` first, and on 403 / a CF-challenge
body, retry through the impersonate binary. That covers the JA3/h2 tier without proxies.

---

## (d) Honest limits — what we simply can't do here

- **CAPTCHA** (Cloudflare Turnstile, reCAPTCHA, hCaptcha): **not solvable** without an
  external solver service or a real interactive browser. Out of scope for self-host.
- **The hardest WAF tier with full browser-environment attestation** (WebGL/canvas/audio
  fingerprint, behavioral mouse/timing biometrics, CF "managed challenge" JS): **not
  passable in a JS-DOM** (StarlingMonkey/Blitz). Needs a real browser engine — i.e. the
  hosted-browser services exist precisely for this slice.
- **Chrome-identical JA3/JA4 from Erlang `:ssl`**: impossible (no ClientHello control).
  The only self-host route is the brokered curl-impersonate binary (or a heavy uTLS-in-
  wasm port). Even then, JA4 + extension-randomization means impersonation is a moving
  target needing maintenance — **comparable, never perfect**.
- **IP reputation / geo / rate-based blocks**: by definition need egress we've excluded;
  the user brings their own.

**Bottom line:** steps #1–4 (pure-Elixir header/cookie/decompression realism) get us
*comparable* reach to a hosted browser on **normal and baseline-Cloudflare** sites — the
80/20 for our agentic use case — for trivial effort. curl-impersonate (host-brokered)
extends that to the JA3/h2 hard tier. CAPTCHA and full browser-attestation challenges
remain genuinely out of reach without external services or a real browser, and we should
say so rather than pretend.

### Sources
- https://meta.wikimedia.org/wiki/User-Agent_policy
- https://www.capsolver.com/blog/All/web-scraping-with-curl-cffi
- https://webclaw.io/blog/tls-fingerprint-vs-browser-cloudflare
- https://scrapfly.io/web-scraping-tools/ja3-fingerprint
- https://scrapfly.io/blog/posts/curl-impersonate-scrape-chrome-firefox-tls-http2-fingerprint
- https://github.com/lexiforest/curl_cffi
- https://brightdata.com/blog/web-data/web-scraping-with-curl-cffi
- https://developers.cloudflare.com/bots/additional-configurations/ja3-ja4-fingerprint/
- Live probes (this machine, 2026-06-18): Wikipedia UA test, CF/HN/Amazon/G2/nowsecure.nl reachability, HTTP/1.1-vs-CF.
