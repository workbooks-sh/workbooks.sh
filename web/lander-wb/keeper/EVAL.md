# lander-live — production DX evaluation (bd wb-5vm)

Bringing up the self-maintaining lander using ONLY production surfaces, and
grading the experience while doing it. Two axes per item: **ability** (did it
work) and **ergonomics** (what it cost in friction). Friction notes are logged
live, verbatim, as encountered — they become bd issues.

## Test matrix

| # | What's under test | Production surface | Ability | Ergonomics | Friction |
|---|---|---|---|---|---|
| 1 | CLI distribution | `npm i -g @work.books/cli` (the v0.11.0 release) | ⚠ works only authed | poor today | #1 #2 #3 |
| 2 | Deploy-kit → cloud | `wb deploy secrets set` + `wb deploy apply` (fly recipe, prebuilt ghcr image) | | | |
| 3 | Runtime serves the page | publish the lander INTO the deployed runtime; page at the fly URL | | | |
| 4 | Instance toolkit | living-lander toolkit (agent + brand north star + analytics + publish skills) | ✓ verify 7/7 | good — native eval caught a real gap | #4 |
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

### Friction #4 — toolkit pre-block evals have no defined cwd (test 4)
`:role pre` probes run under the sandbox with an undefined working directory —
relative paths to the toolkit's own files (`../assets/components.html`) fail.
Authors can't write self-checks against their own toolkit content, which guts
half the value of the native eval. Fix: run pre/task blocks with cwd = the
toolkit dir (sandbox-confined there), or export WB_TOOLKIT_DIR. Severity:
medium-high for toolkit DX. Workaround: cwd-independent probes only.

### Friction #5 — deployed control plane is open by default (test 2)
Workbooks.Auth: no Bearer → x-tenant dev-header fallback. Fine for local; on a
public fly app it means ANYONE can hit /api/run (spend money), /rcp/toolkit/install
(plant a toolkit), PUT /w/:id (replace the page). Acceptable for this demo box,
unacceptable default for `wb deploy` cloud targets. Fix: deploy-kit mints
WB_PUBLIC_BEARER (it already refuses to mint rotating secrets — this one should
be a persisted operator secret it ASKS for), engine requires it when
WB_TENANCY_MODE != dev. Severity: HIGH for any real deployment.
