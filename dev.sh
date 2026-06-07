#!/usr/bin/env bash
# AdBuy iOS dev loop — live reload on physical device or Simulator.
#
# DEVICE (default): builds the native shell once if needed, then starts a Vite
# dev server. The already-installed app connects over WiFi — no rebuild on JS/HTML/CSS changes.
# SIMULATOR: faster launch, no WiFi needed, no haptics.
#
# Usage:
#   ./dev.sh              # auto-detect: use a tethered/wireless device
#   ./dev.sh --sim        # iOS Simulator (no signing, no device)
#   ./dev.sh --build-sim  # rebuild the Rust sim first, then launch
#   ./dev.sh --host-only  # just start the Vite server (app already installed)
#
# Requirements:
#   - Xcode + iOS Simulator (for --sim) OR a physical device trusted on this Mac
#   - wasm-pack (for --build-sim): cargo install wasm-pack
#   - node/npm: brew install node
#
# On first run this installs npm deps + adds the iOS native project (~2-5 min).
# Subsequent runs skip that and just start the dev server (~5 sec).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

MODE="device"
BUILD_SIM=0
HOST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --sim) MODE="sim" ;;
    --build-sim) BUILD_SIM=1 ;;
    --host-only) HOST_ONLY=1 ;;
  esac
done

# ── 1. optionally rebuild the Rust sim ───────────────────────────────────────
if [[ $BUILD_SIM -eq 1 ]]; then
  echo "==> building Rust sim -> app/pkg/"
  bash sim-rs/build.sh
elif [[ ! -f app/pkg/adbuy_sim.js ]]; then
  echo "==> app/pkg/ missing — building Rust sim first"
  bash sim-rs/build.sh
fi

# ── 2. npm install (cached after first run) ───────────────────────────────────
if [[ ! -d node_modules ]]; then
  echo "==> npm install (first run — installs Capacitor + Vite)"
  npm install --no-audit --no-fund
fi

# ── 3. add the iOS native project (once) ─────────────────────────────────────
if [[ ! -d ios ]]; then
  echo "==> npx cap add ios (generates native Xcode project — one-time, ~1 min)"
  npx cap add ios
fi

# ── 4. sync web assets into the native project ───────────────────────────────
echo "==> npx cap sync ios"
npx cap sync ios

# ── host-only: just start the server (native shell already on device) ─────────
if [[ $HOST_ONLY -eq 1 ]]; then
  echo "==> starting Vite dev server (app already installed — open it on your device)"
  echo "    serving on http://0.0.0.0:5173"
  exec npx vite app --host 0.0.0.0 --port 5173
fi

# ── 5. get LAN IP for live reload ─────────────────────────────────────────────
LAN_IP=""
if [[ "$MODE" == "device" ]]; then
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  if [[ -z "$LAN_IP" ]]; then
    echo "warning: no LAN IP on en0/en1 — falling back to Simulator mode"
    MODE="sim"
  fi
fi

# ── 6. inject server.url for live reload (strip it after, for safety) ─────────
if [[ "$MODE" == "device" ]]; then
  trap 'node -e "const f=require(\"fs\"),c=JSON.parse(f.readFileSync(\"capacitor.config.json\"));delete c.server;f.writeFileSync(\"capacitor.config.json\",JSON.stringify(c,null,2))" 2>/dev/null; echo "==> server.url cleared from capacitor.config.json"' EXIT

  node -e "
    const f = require('fs');
    const c = JSON.parse(f.readFileSync('capacitor.config.json'));
    c.server = { url: 'http://${LAN_IP}:5173', cleartext: true };
    f.writeFileSync('capacitor.config.json', JSON.stringify(c, null, 2));
  "
  echo "==> live reload -> http://${LAN_IP}:5173"
  echo "    (server.url set in capacitor.config.json; cleared on exit)"
fi

# ── 7. start Vite in background ───────────────────────────────────────────────
npx vite app --host 0.0.0.0 --port 5173 &
VITE_PID=$!
trap "kill $VITE_PID 2>/dev/null; wait $VITE_PID 2>/dev/null; exit 0" INT TERM

# Give Vite a moment to start
sleep 2

# ── 8. launch on device or Simulator ─────────────────────────────────────────
if [[ "$MODE" == "sim" ]]; then
  # Simulator: no --external, localhost works
  target="$(xcrun simctl list devices available 2>/dev/null \
    | grep -E 'iPhone' | grep -Eo '[0-9A-F-]{36}' | head -1 || true)"
  if [[ -n "$target" ]]; then
    echo "==> cap run ios --simulator (UDID: $target)"
    npx cap run ios --target "$target" --live-reload --host 0.0.0.0 --port 5173 || true
  else
    echo "no available iPhone Simulator — opening Xcode instead"
    npx cap open ios
  fi
else
  # Physical device: --external to bind to LAN IP, not localhost
  echo "==> cap run ios --live-reload --external (device over WiFi)"
  echo "    If Xcode prompts for trust, accept on your iPhone."
  echo "    After first install, just run: ./dev.sh --host-only"
  npx cap run ios --live-reload --external --host 0.0.0.0 --port 5173 || {
    echo ""
    echo "==> 'cap run ios' failed — device may not be trusted yet."
    echo "    Connect iPhone via USB, trust this Mac, then re-run ./dev.sh"
    echo ""
    echo "    Alternatively: ./dev.sh --sim (uses the Simulator, no device needed)"
  }
fi

# Keep Vite alive if cap run exits (e.g. app was installed; user just needs server)
echo ""
echo "==> Vite server still running on http://0.0.0.0:5173"
echo "    Open the app on your device — it will connect automatically."
echo "    Ctrl-C to stop."
wait $VITE_PID
