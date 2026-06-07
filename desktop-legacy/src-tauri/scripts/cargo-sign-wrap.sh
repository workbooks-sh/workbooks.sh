#!/bin/bash
# Cargo wrapper that codesigns the resulting binary with the user's
# Apple Development identity BEFORE executing it.
#
# Wired in via `build.runner` in tauri.conf.json. Tauri invokes us
# as:
#
#   ./scripts/cargo-sign-wrap.sh run --no-default-features --features X --color always -- ARGS
#
# The naive `exec cargo "$@"` flow doesn't work for `cargo run`:
# cargo would build + exec the binary in one step, and we'd never
# get a chance to codesign between them. Our wrapper splits the
# step: cargo build → codesign → exec the (now-signed) binary.
#
# For `cargo build` and `cargo test`, we pass through and codesign
# the output afterwards.
#
# Why: without a stable code signature, macOS treats every dev
# rebuild as a new application. Keychain ACLs (the "Always Allow"
# you click on the OPENROUTER_API_KEY prompt) are bound to the
# code-signing certificate's identity, so a stable signature means
# the prompt fires ONCE per cert, not once per rebuild.
#
# Identity discovery is automatic: the first "Apple Development:"
# cert in the keychain wins. Nothing committed to the repo.
# Environments without a developer cert keep working unsigned.

set -eo pipefail

CMD="$1"

# Resolve the Apple Development identity once. If none exists, skip
# signing entirely — keep dev working on machines without a cert.
IDENTITY=$(
  security find-identity -v -p codesigning 2>/dev/null \
    | grep '"Apple Development:' \
    | head -1 \
    | sed -n 's/.*"\(.*\)".*/\1/p'
)

if [ -z "$IDENTITY" ]; then
  # No cert → just pass through and let cargo do its normal thing.
  # User gets the per-launch keychain prompts they had before.
  exec /usr/bin/env cargo "$@"
fi

PKG_NAME="workbooks-desktop"
BIN_PATH=""

# Codesign helper. Idempotent — --force replaces existing signatures.
# --options runtime is harmless in dev and required for notarized
# release. Grep filters the noise of "replacing existing signature".
codesign_bin() {
  local bin="$1"
  if [ -x "$bin" ]; then
    codesign --sign "$IDENTITY" --force --deep --options runtime "$bin" 2>&1 \
      | grep -v "replacing existing signature" || true
  fi
}

case "$CMD" in
  run)
    # Strip "run" from the argv; pass the rest to `cargo build`.
    # Then codesign + exec the resulting binary with any post-`--`
    # args.
    shift  # drop "run"

    # Split args at `--` — anything after is binary args, not cargo
    # args. Anything before goes to `cargo build`.
    BUILD_ARGS=()
    BIN_ARGS=()
    SEEN_DASHDASH=0
    for arg in "$@"; do
      if [ "$arg" = "--" ]; then
        SEEN_DASHDASH=1
        continue
      fi
      if [ $SEEN_DASHDASH -eq 1 ]; then
        BIN_ARGS+=("$arg")
      else
        BUILD_ARGS+=("$arg")
      fi
    done

    /usr/bin/env cargo build "${BUILD_ARGS[@]}"
    BUILD_EXIT=$?
    [ $BUILD_EXIT -ne 0 ] && exit $BUILD_EXIT

    # Determine which profile we built. Default debug; --release
    # flips to release.
    PROFILE="debug"
    for arg in "${BUILD_ARGS[@]}"; do
      if [ "$arg" = "--release" ]; then
        PROFILE="release"
        break
      fi
    done

    BIN_PATH="target/${PROFILE}/${PKG_NAME}"
    if [ ! -x "$BIN_PATH" ]; then
      echo "[cargo-sign-wrap] ERROR: binary not found at $BIN_PATH"
      exit 1
    fi

    codesign_bin "$BIN_PATH"

    # Hand off to the (now-signed) binary. exec replaces our PID so
    # the binary inherits stdio + signal handling cleanly.
    exec "$BIN_PATH" "${BIN_ARGS[@]}"
    ;;

  build|test)
    # Pass through to cargo, then codesign whatever it produced.
    /usr/bin/env cargo "$@"
    CARGO_EXIT=$?
    [ $CARGO_EXIT -ne 0 ] && exit $CARGO_EXIT

    for profile in debug release; do
      bin="target/${profile}/${PKG_NAME}"
      [ -x "$bin" ] && codesign_bin "$bin"
    done
    exit $CARGO_EXIT
    ;;

  *)
    # Other cargo subcommands (check, clippy, fmt, etc.) — just pass
    # through; nothing to sign.
    exec /usr/bin/env cargo "$@"
    ;;
esac
