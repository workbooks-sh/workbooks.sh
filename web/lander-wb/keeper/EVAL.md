# lander-live — production DX evaluation (bd wb-5vm)

Bringing up the self-maintaining lander using ONLY production surfaces, and
grading the experience while doing it. Two axes per item: **ability** (did it
work) and **ergonomics** (what it cost in friction). Friction notes are logged
live, verbatim, as encountered — they become bd issues.

## Test matrix

| # | What's under test | Production surface | Ability | Ergonomics | Friction |
|---|---|---|---|---|---|
| 1 | CLI distribution | `npm i -g @work.books/cli` (the v0.11.0 release) | | | |
| 2 | Deploy-kit → cloud | `wb deploy secrets set` + `wb deploy apply` (fly recipe, prebuilt ghcr image) | | | |
| 3 | Runtime serves the page | publish the lander INTO the deployed runtime; page at the fly URL | | | |
| 4 | Instance toolkit | author a `lander` toolkit (analytics + publish skills) for the keeper | | | |
| 5 | Agent on schedule | keeper (DeepSeek V4) runs hourly via a scheduled trigger → one constrained edit | | | |
| 6 | Observable loop | /rcp/changes live in the page inspector; commits cite analytics | | | |
| 7 | CI round-trip | any runtime gap found → fix → push → image rebuilds → redeploy picks it up | | | |
| 8 | CF-fronted hosting | workbooks.sh CF worker proxies /live/* → the fly engine (page through Cloudflare) | | | |

## Friction log (live)

(appended during the run)

## Verdicts

(filled at the end: what was hard, what we fix, what the DX should feel like)

### Friction #1 — CLI install shadowed by stale binary (test 1)
`npm i -g @work.books/cli` succeeded, but `which wb` still resolved to a stale
`~/.local/bin/wb` from earlier development — PATH precedence silently shadows
the npm install. A user who ever had ANY old wb would hit this and blame the
product. **Fix candidates:** postinstall PATH-conflict warning ("another wb at
…/.local/bin/wb will shadow this install"), and/or `wb doctor` surface.
Severity: medium (silent wrong-version). Workaround: rm the stale binary.

### Friction #2 — postinstall failure is silent (test 1)
install.js soft-fails by design (exit 0) and npm hides script output by default
→ a failed download yields a broken `wb` with no warning at install time. The
runtime shim message is good, but the failure should be loud at install.
Fix: print a clear post-install summary line; consider failing hard when the
platform asset is definitively absent. Severity: medium.

### Friction #3 — CRITICAL: private repo breaks ALL distribution (tests 1+2)
github.com/workbooks-sh/workbooks.sh is PRIVATE → release assets 404 for anyone
unauthenticated. This breaks: npm postinstall download, curl cli.sh, AND the
existing desktop install.sh on workbooks.sh (same repo!). Nothing in CI warned;
publish "succeeded." DECISION (founder): make repo public (matches the
Apache-2.0 / open-source positioning) or host artifacts elsewhere (R2 bucket
behind workbooks.sh). Until then: every install path is broken for the public.
Severity: CRITICAL — silent, total distribution failure.
