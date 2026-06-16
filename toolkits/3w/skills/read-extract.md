# 3w — read a URL as clean markdown (JS-aware)
0.1.0
Use when you have a URL and want its readable content. Chrome-impersonating fetch + readability → markdown; auto-escalates to a real JS render only when the page needs it.

# When to use this
NETWORK: yes
DESTRUCTIVE: no
COST: free

  Use when you have a URL (often from [search](search.md)) and want its
  main content as markdown — an article, a docs page, a product page. =3w read
  <url>= strips chrome/nav/ads and returns the readable core.
  NOT for: finding URLs (that's [search](search.md)); capturing a
  page's network traffic / hidden JSON feeds (a later `3w har` verb);
  multi-page crawls (a later `3w crawl` verb).

# The mental model — two tiers, auto-selected

  | Tier      | How                                          | When                        |
  |-----------|----------------------------------------------|-----------------------------|
  | `Http`    | wreq (Chrome TLS/HTTP2 impersonation) + readability | default; most pages         |
  | `Render`  | `lightpanda fetch --dump markdown` (runs JS) | page is a JS shell          |

  Tier 1 is cheap and clears Cloudflare/Akamai network-tier walls that `curl`
  trips, because it presents a real Chrome fingerprint. The reader escalates to
  tier 2 *only* on a JS-shell signal (explicit "enable javascript" text, or
  near-empty extraction on a script-heavy document) — a small static page like
  example.com stays on tier 1. Check the `tier` field in `--json` to see which
  ran. Force a render with `--render` when you already know the page is an SPA.

# Workflow

## pre — the 3w binary is available
```bash
  command -v 3w >/dev/null || { echo "3w not on PATH"; exit 1; }
```

## read a page — markdown to stdout
```bash
  3w read "https://prudentreviews.com/caraway-cookware-review/"
```

## structured — see the tier, status, title alongside the markdown
```bash
  3w read "https://example.com" --json
  # → {url,title,markdown,status,tier}
```

## force a JS render for a known SPA (skips tier 1)
```bash
  3w read "https://some-react-app.example/page" --render
```

## post — extraction produced real content
```bash
  3w read "https://example.com" --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "Example Domain" in d["markdown"]; print("tier:", d["tier"])'
```

# Common pitfalls

  1. *Using `curl` instead.* → No JS, trivial bot-walls, no extraction. → Use
     `3w read`; it impersonates Chrome and extracts the main content.
  2. *Forcing `--render` everywhere.* → Spins up Lightpanda (slower) for pages
     that don't need it. → Trust the auto-escalation; only `--render` a known
     SPA.
  3. *Empty markdown on a heavy SPA.* → Lightpanda lacks some Web APIs and can
     blank-render. → See [troubleshoot](troubleshoot.md) (wait flags /
     fall back to a later `3w browse`).
  4. *Reading a search-result redirect URL.* → Some engines wrap URLs. → 3w's
     adapters unwrap them, but if a URL looks like a tracker, read the
     unwrapped destination, not the redirector.
  5. *Assuming =status=200= means good content.* → A soft-blocked page can be
     200 with a shell body. → Check the `markdown` is non-trivial; if it's a
     consent/JS stub, [troubleshoot](troubleshoot.md).

# Verification checklist

  - [ ] `3w read https://example.com --json` has `tier: "Http"` (no needless render)
  - [ ] `markdown` contains the page's main text, not nav/ads
  - [ ] A known SPA returns content under `--render` (`tier: "Render"`)
  - [ ] `title` is populated for a normal article

# See also

  - [search](search.md) — find URLs to read
  - [overview](overview.md) — verb map + what's live
  - [troubleshoot](troubleshoot.md) — empty / shell / walled reads
