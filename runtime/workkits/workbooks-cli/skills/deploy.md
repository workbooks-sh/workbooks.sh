# workbooks-cli — deploy

# How to invoke (read this first)

  These are BUILT-IN `work` verbs. Run them DIRECTLY through your `work` tool —
  e.g. args="deploy status". Do NOT wrap them in `work toolkit run …` (that path is
  for compiled command-toolkits and will be refused for deploy). The command is
  literally `work deploy <verb>`, nothing more.

# Stand up + operate a runtime (a "nexus")

  `work deploy` brings THE runtime image up to a declared state. Two homes:
  - LOCAL — a krunvm container on the user's mac (same OCI image as cloud).
  - CLOUD — Fly, from `./deployment.org`.

  All verbs are non-interactive; add `--json` for machine output (exit 0 ok).

# Fastest path: zero-config local

  : work deploy doctor     ;; first — can this host deploy? (container runtime + creds)
  : work deploy local      ;; bring up a local runtime with no file, like `docker run`
  : work deploy status     ;; confirm it's up
  : work deploy verify     ;; health-check it
  : work deploy down       ;; stop it

# Declarative path: deployment.org

  When the target is cloud (or you want it reproducible / in CI):

  : work deploy init fly      ;; scaffold ./deployment.org for a Fly target
  ;; → user edits deployment.org (app name, region, secrets-by-reference, image)
  : work deploy validate      ;; coherence-check WITHOUT applying — always do this first
  : work deploy apply         ;; reconcile the runtime to the file
  : work deploy status        ;; ./deployment.org if present (local OR cloud), else local daemon
  : work deploy logs          ;; tail
  : work deploy down          ;; tear down

# Make it git-native (CI)

  : work deploy ci github     ;; scaffold a workflow that runs `work deploy apply` on push
  ;; (also: gitlab | generic). deployment.org becomes the source of truth; pushes reconcile.

# The image verbs (only when asked)

  : work deploy build         ;; build the one OCI image (into krunvm)
  : work deploy publish       ;; push it to a registry the USER controls (WB_IMAGE)

  These are for the user shipping THEIR runtime. They are NOT the platform's
  compilers-package / platform-runtime release (maintainer-only) — never conflate.

# Honesty + safety

  - Always `validate` before `apply`; report the validate output, don't assume.
  - `down` is destructive (stops the runtime) — confirm intent before running it
    against a cloud target.
  - If `doctor` reports a missing container runtime or creds, say exactly that and
    stop — don't pretend `apply` will work.
