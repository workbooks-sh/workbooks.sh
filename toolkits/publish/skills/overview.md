# publish — overview
0.1.0
Use when a task involves publishing a workbook to the AT Protocol / Bluesky network, or moving/binding the Workbooks Network identity. First contact for the toolkit.

# When to use this
NETWORK: yes
DESTRUCTIVE: no

  Reach for this toolkit when the user wants to publish a built
  workbook to their Bluesky/AT Protocol account, verify what's
  bound, watch the verified workbook feed, or move their Workbooks
  identity (did:key) to another machine. `work identity …` and
  `work atproto …` pass through here, so either spelling works.

# Workflow

## 1. confirm the toolkit binary is reachable
```bash
  command -v wb-publish >/dev/null || { echo "wb-publish missing — cargo install --path toolkits/publish/bin"; exit 1; }
  wb-publish --help 2>&1 | head -1
```

## 2. inspect the bound identity (engine-free)
```bash
  wb-publish identity show
  wb-publish atproto status
```

## 3. bind a Bluesky account standalone (no engine; opens browser)
```bash
  wb-publish identity bluesky-oauth-login --handle alice.bsky.social --standalone
```

## 4. publish a built workbook; prints the at:// URI
```bash
  wb-publish atproto publish dist/my-book.html --title "My book"
```

## 5. undo a publish by its at:// URI
```bash
  wb-publish atproto delete 'at://did:plc:…/sh.workbooks.workbook/…'
```

# Common pitfalls

  1. Agent-driven OAuth: pass `--no-open --json` to
     `bluesky-oauth-login` so the auth URL is printed (JSON lines)
     instead of a browser being opened on a headless box.
  2. `bluesky-login` (app password) and oauth login WITHOUT
     `--standalone` need a running engine; use `--standalone` when
     only public publishing is wanted.
  3. `atproto publish --sign` is reserved — pre-sign with `work seal`
     instead.

# Verification checklist

  - [ ] `wb-publish atproto status` shows the expected did + handle
  - [ ] publish printed an `at://` URI (and `--json` parses)

# See also
  - manifest.org — toolkit surface + engine contract
