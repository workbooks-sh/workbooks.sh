# 3w — troubleshoot (empty, walled, CAPTCHA'd, shell renders)
0.1.0
Use when a 3w search or read came back empty, blocked, CAPTCHA'd, or rendered a JS shell. The bot-wall / empty-render playbook, seeded from spike findings.

# When to use this
NETWORK: yes
DESTRUCTIVE: no
COST: free

  Use when a result is wrong-shaped: no search hits, a read returned a
  consent/JS stub, a 403/429, or a CAPTCHA page. This is the decision tree for
  routing around it.
  NOT for: normal usage ([search](search.md) /
  [read-extract](read-extract.md)).

# The mental model — why walls happen

  Three independent signals get a request blocked: *TLS/HTTP2 fingerprint*
  (does it look like Chrome?), *IP reputation* (datacenter vs residential,
  request rate), and *JS/behavioral* (does it execute a challenge?). `3w`
  already fixes #1 (Chrome impersonation via wreq) and partially #3 (Lightpanda
  renders JS). What's left for you to turn: IP (proxy), engine choice, and
  wait/selector tuning.

# Playbook

## Search returned nothing
## pre — 3w available
```bash
   command -v 3w >/dev/null || { echo "3w not on PATH"; exit 1; }
```

## widen the engine pool + simplify the query
```bash
   3w search "<3-6 key terms>" --engines ddg,bing,brave,mojeek --n 10
   # one engine may be transiently walled; the other three still answer
```

   - Still empty? The query is too narrow or the topic is genuinely sparse —
     rephrase with different keywords. Do NOT reach for Google (excluded by
     design).

## Read returned a JS shell / near-empty markdown
## force a real render with a longer wait
```bash
   3w read "<url>" --render --json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["tier"],len(d["markdown"]))'
```

   - Lightpanda lacks some Web APIs and can blank-render SPAs. If `--render`
     still yields little, the page needs a full browser → fall back to
     `3w browse` (when live) or flag the URL for the heavy-browser tier.

## 403 / 429 / CAPTCHA on a read
## route through a residential proxy (IP reputation is often the real signal)
```bash
   WB_WEB_PROXY="http://user:pass@residential-proxy:port" 3w read "<url>"
```

   - Ensure the Chrome profile is current (stale = fingerprints as old Chrome).
   - If it's a search engine CAPTCHA: *switch engines*, don't fight it.

## A page hides its data behind XHR (renders, but the data isn't in the HTML)
   - This is the `3w har` case (coming): capture the network session and hit
     the JSON endpoint the page itself calls — cleaner and cheaper than parsing
     rendered HTML. Until then, `--render` and parse the populated DOM.

# Common pitfalls

  1. *Retrying the same walled request unchanged.* → Same fingerprint + IP =
     same block. → Change one variable: engine, proxy, or render tier.
  2. *Blaming 3w for a Google block.* → Google is excluded on purpose. → Use
     the native pool or a paid SERP backend.
  3. *Cranking `--render` on everything after one shell page.* → Most pages
     don't need it. → Render only the page that actually failed.
  4. *Ignoring the proxy lever.* → Fingerprint is fixed; IP often isn't. →
     `WB_WEB_PROXY` is the highest-leverage knob for reputation blocks.

# Verification checklist

  - [ ] After widening engines, a previously-empty common query returns hits
  - [ ] A known SPA returns content under `--render`
  - [ ] `WB_WEB_PROXY` is honored (request egresses from the proxy IP)

# See also

  - [search](search.md) — normal search
  - [read-extract](read-extract.md) — normal reads + the tier model
  - [overview](overview.md) — the rules that avoid walls in the first place
