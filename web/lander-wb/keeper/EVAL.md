# lander-live — production DX evaluation (bd wb-5vm)

Bringing up the self-maintaining lander using ONLY production surfaces, and
grading the experience while doing it. Two axes per item: **ability** (did it
work) and **ergonomics** (what it cost in friction). Friction notes are logged
live, verbatim, as encountered — they become bd issues.

## Test matrix

| # | What's under test | Production surface | Ability | Ergonomics | Friction |
|---|---|---|---|---|---|
| 1 | CLI distribution | `npm i -g @work.books/cli` (the v0.11.0 release) | ✓ installs working wb (repo public) | fixed #1 #2 | #1 #2 #3 RESOLVED |
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

### Resolutions
- #1 PATH-shadow warning + #2 loud postinstall failure: fixed in cli/npm (install.js, bin/wb.js).
- #3 CRITICAL private-repo 404: RESOLVED — founder made repo public; `npm i -g @work.books/cli` now installs a working wb unauthenticated. Verified.
- #4 toolkit eval cwd: fixed in toolkits.ex — pre/task blocks run with cwd = toolkit dir + WB_TOOLKIT_DIR exported. verify 7/7.
- #5 open control plane: RESOLVED — auth.ex 3-rung ladder (WB_PUBLIC_BEARER locks the plane, 401 no-fallback when set); deploy-kit auto-generates+persists the bearer on cloud apply (ensure_cloud_bearer, not rotated); local stays open. 7/7 auth tests. SECURE BY DEFAULT for every wb deploy cloud user, not just our box.

## Hosting decision (founder, 2026-06-09)
Model A — serve the lander LIVE from the fly runtime (PublicWeb live-render),
NOT render-and-push to CF static. Rationale: the page rewrites itself; live
render makes every new load the current page instantly (no publish hop). CF
stays as the /live/* edge proxy (TLS/cache/DDoS) — free upside. Verified no
added security risk: public plane is GET-only, non-executing, plane-split;
control plane now bearer-locked. Caveat recorded: an already-open tab still
needs a client poll to update without reload (filed, optional).

### Friction #6 — declared secrets are all-required, no optional tier (test 2)
deployment.org `#+DEPLOY_SECRETS` treats every name as mandatory; `wb deploy
apply` refuses until ALL are set. Good gate, but there's no way to mark a
secret OPTIONAL (e.g. POSTHOG_API_KEY — analytics is a later phase, keeper
works without it). Workaround: drop it from the declared list. Fix idea:
`#+DEPLOY_SECRETS_OPTIONAL:` or a `name?` suffix. Severity: low (real DX paper-cut). Caught by the deploy gate doing its job.

### Friction #7 — deploy-kit doesn't size the machine for the runtime (test 2)
HIGH. First `wb deploy apply` to fly came up in a CRASH LOOP: beam.smp OOM-killed
(default shared-cpu-1x ~512MB; BEAM + wasmtime needs >1GB). App bound 0.0.0.0:4000
then died repeatedly; /health 502; the auto-bearer never persisted because the
app never got healthy. The fly API "apply" reported success — the failure was
only visible in logs. Fix: deploy-kit must set adequate VM memory for the
runtime image by default (≥1GB, recommend 2GB) + a #+DEPLOY_MEMORY knob; ideally
poll /health post-apply and surface OOM. Workaround: `fly scale memory 2048`.
Severity: HIGH — a first-time cloud deploy silently crash-loops.

### Friction #8 — fly serves a STALE :latest; image builds were silently failing (tests 2/7)
HIGH. `wb deploy apply` pulled ghcr `:latest`, but `:latest` was pinned to a
pre-auth-fix sha (871bac7) because the runtime-image builds for the newer shas
had FAILED (wbox.c missing from build context — .dockerignore excluded
runtime/compilers/). So the deployed engine ran old code: auth lock absent,
control plane open, despite the secret being present. Diagnosis took a full
image-digest/commit-ancestry trace. Fixes: (a) the wbox.c path bug was fixed in
a parallel effort (moved to host/wbox/), :latest now 943a342 with the lock; (b)
deploy-kit should PIN by sha (not float :latest) and/or verify the running
digest post-apply. Resolved by redeploying `--image …:943a342`. Lock then
verified: no-bearer/wrong→401, correct→202, /health→200.

### Friction #9 — BLOCKER: single fly machine doesn't expose the public content plane (test 3)
The runtime has TWO listeners: control plane (authed, Workbooks.Web, :4000) and
the anonymous content plane (Workbooks.PublicWeb, :4001, WB_PUBLIC=1). deploy-kit
brings up only the control plane and fly routes :443→:4000, so GET / hits the
AUTHED plane → 401; the page-serving plane is neither started nor exposed.
Serving the lander publicly while keeping an authed control plane for the keeper
on ONE machine needs a deploy-kit decision:
  (A) two fly [[services]] / ports — public plane on the exposed port, control
      plane internal-only (keeper hits localhost; needs the runtime-native
      scheduler, not GH-cron-over-public-URL);
  (B) a front-router plug that dispatches by path (/api,/rcp,/w → control;
      else → public) on one port;
  (C) public plane on the exposed port + control plane on a second exposed port
      behind the bearer.
Recommend (A): also removes any public control-plane exposure (most secure).
This is the last gap before the page is live; it's an architecture call.
