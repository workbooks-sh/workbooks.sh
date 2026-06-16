# wraith — enforce module import boundaries from .wraithrc.json
0.1.0
Use when codifying which crates / modules are allowed to import which others. Configure `boundaries` rules in `.wraithrc.json`, then run `wraith boundaries` to surface violations.

# When to use this
NETWORK: no
DESTRUCTIVE: no
REQUIRES: wraith>=0.0.0

  The codebase has a layered architecture the team wants to
  protect — e.g. `-cli` crates must not be imported by
  `-core`; `api` must not import from `db`; the agent runtime
  must not pull in desktop-only code. Encoding those rules in
  `.wraithrc.json` lets `wraith boundaries` flag the next
  violation before it lands.

  Not for: enforcing visibility within a single crate (use
  `wraith visibility` for that); detecting cycles (use
  `wraith circular-deps`); or removing already-dead imports
  (use `wraith dead-code` + `wraith fix`).

# The rule shape

  Each boundary rule has three fields:

  | Field    | Meaning                                                                   |
  |----------|---------------------------------------------------------------------------|
  | `from`   | The crate (by name) OR a path prefix that must obey the rule              |
  | `allow`  | Import-path prefixes that this crate IS permitted to use                  |
  | `deny`   | Import-path prefixes that this crate is NOT permitted to use (wins over allow) |

  Matching semantics (verified from
  `wraith-core/src/boundaries.rs`):
  - `from` matches if it equals the crate name OR if the
    crate's root-dir relative path STARTS WITH the `from`
    string. So both `"wraith-cli"` and `"crates/wraith-cli"`
    work — name-match is most portable.
  - For each external reference (`root::name` where `root` is
    something like `wraith_core`, `serde`, `std`), the import
    path `root::name` is compared with each `allow` and `deny`
    prefix. Prefix match wins.
  - `std`, `core`, `alloc`, `crate`, `self`, `super`, `Self`
    are always skipped — boundary rules only see crate-external
    imports.
  - Empty rules list = checker is a no-op.

# Workflow

## 1. confirm wraith binary + read current config
```bash
  command -v wraith >/dev/null \
    || { echo "wraith missing"; exit 1; }
  test -f .wraithrc.json \
    || { echo ".wraithrc.json missing — run 'wraith init' first"; exit 1; }
  jq '.boundaries // []' .wraithrc.json
```

## Step 1 — generate a baseline config if needed

## scaffold .wraithrc.json with defaults
```bash
   wraith init
   # writes .wraithrc.json with empty boundaries: []
```

   The default produced has this shape (verified by running
   `wraith init` against an empty repo):

```json
   {
     "ignore":                    ["target", "node_modules", ".git"],
     "allow_dead":                [],
     "allow_unused_deps":         [],
     "treat_pub_crate_as_internal": true,
     "duplicates":                { "min_tokens": 40, "similarity_threshold": 0.85 },
     "complexity":                { "cyclomatic": 15, "cognitive": 25 },
     "boundaries":                []
   }
```

## Step 2 — add a deny-only rule (most common pattern)

   The `-core` crate must not import anything from any `-cli`
   crate (CLIs sit above core in the layering).

## edit .wraithrc.json — add a deny rule
```json
   {
     "boundaries": [
       {
         "from": "wraith-core",
         "deny": ["wraith_cli"]
       }
     ]
   }
```

   Note the underscore in `wraith_cli`. The `root` segment
   of a Rust import path uses the crate's Rust identifier
   (hyphens → underscores). `from` still uses the Cargo
   package name.

## Step 3 — add an allow-only rule (whitelist mode)

   Restrict `services-broker` to only import from a curated
   set of crates. Anything else is denied by absence.

## whitelist style — only listed prefixes allowed
```json
   {
     "boundaries": [
       {
         "from":  "services-broker",
         "allow": [
           "broker_core",
           "broker_db",
           "serde",
           "tokio",
           "tracing"
         ]
       }
     ]
   }
```

   When `allow` is present, references whose root doesn't
   prefix-match any entry are reported as violations. (Today's
   semantics: `deny` overrides `allow`; absence of both means
   no rule applies. For pure whitelisting use only `allow`.)

## Step 4 — mix allow + deny for nuanced layering

   The desktop crate may import from `desktop-ui` AND any
   `workbooks_runtime_*` module — EXCEPT it must never reach
   into the BYOD storage internals.

## combined allow + deny
```json
   {
     "boundaries": [
       {
         "from":  "apps-desktop",
         "allow": ["desktop_ui", "workbooks_runtime"],
         "deny":  ["workbooks_runtime::byod::internal"]
       }
     ]
   }
```

   The `deny` prefix overrides the `allow` prefix, so this
   crate gets the runtime in general but is gated out of
   byod's internal modules.

## Step 5 — run the check

## surface every current violation
```bash
   wraith boundaries
```

## same, machine-readable for an agent or CI step
```bash
   wraith --format json boundaries | jq '.[] | select(.kind == "boundary")'
```

## Step 6 — wire into CI (optional)

## fail CI if any boundary violation surfaces
```bash
   if wraith --format json boundaries | jq -e 'length > 0' >/dev/null; then
     echo "✗ boundary violations present"
     wraith boundaries
     exit 1
   fi
   echo "✓ boundaries clean"
```

   For a permanent install of this check on every PR, see
   `wraith hooks --help` — it installs both a git pre-push hook
   and a Claude Code hook for incremental audits.

# Common pitfalls

  1. *Used hyphenated crate name in `allow` / `deny`.* Won't
     match. Rust's resolved `root` segment is always
     underscored. `from` takes the Cargo package name
     (hyphens fine); `allow` / `deny` take the underscored
     import root.

  2. *Path-prefix `from` doesn't match.* The `from` path is
     matched against the crate's `root_dir` RELATIVE to
     workspace root. `from: "crates/wraith-cli"` works if the
     crate lives at `<workspace>/crates/wraith-cli`. Prefer
     name-match (`from: "wraith-cli"`) — it survives moves.

  3. *Expected std / core to be denyable.* Skipped by design —
     boundary rules don't apply to the stdlib roots. If you
     need to forbid a std module, the right tool is clippy
     restriction lints.

  4. *Rule list is empty — checker is a no-op.* =wraith
     boundaries= silently exits 0 with no findings if
     `boundaries: []`. That's the default after `wraith init`;
     add rules before relying on the check.

  5. *deny wins, but I wanted the narrow allow.* `deny`
     unconditionally overrides `allow` for any prefix that
     matches both. Restructure: drop the broad allow, list
     the narrow allows explicitly.

  6. *Refactored a crate name + forgot the rules.* `from`
     becomes a no-op; the boundary now matches nothing and
     enforces nothing. Treat `.wraithrc.json` as code; review
     it during rename PRs.

# Verification checklist

  - [ ] `.wraithrc.json` exists and has a non-empty `boundaries` list
  - [ ] All `from` names match real crate names (`cargo metadata --format-version 1 | jq -r '.packages[].name'`)
  - [ ] All `allow` / `deny` roots are underscored
  - [ ] `wraith boundaries` reports the expected count (zero or known-baseline)
  - [ ] CI step in place to fail on new violations

# See also

  - [overview](overview.md) — first contact with wraith
  - [clean-up-a-rust-package](clean-up-a-rust-package.md) — dead-code + unused-deps pass
  - [slop-suppression-policy](slop-suppression-policy.md) — what to do about `#[allow(...)]` surfaced en route
  - [fix-write-workflow](fix-write-workflow.md) — apply automatic removals after the audit
