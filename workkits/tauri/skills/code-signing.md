# Code-signing + notarization for a forged desktop app
## The gate between "builds on my machine" and "I can share it." Uses raw cargo tauri build (Tauri reads the signing env vars natively).

# When to use

A workbook has been wrapped into a Tauri desktop app and the user wants to
*share or distribute* it — send the .dmg to someone, put it on a website, ship
it. An UNSIGNED build runs fine on the machine that built it, but every OTHER
machine blocks it: macOS Gatekeeper refuses to open it, Windows SmartScreen
warns sharply. Signing (and on macOS, notarization) is what removes those blocks.

NOTE: there is no `work forge desktop` command (the Rust `work` that provided it,
and its `deploy-kit/desktop/` recipes, were removed 2026-06-09). Build with the
real Tauri CLI — `cargo tauri build` (or `npx @tauri-apps/cli build`) — which
reads the signing env vars below NATIVELY. https://v2.tauri.app/distribute/sign/
is authoritative.

# The mental model

- *Signing* proves the app came from a known developer and wasn't tampered
  with. macOS and Windows both want it.
- *Notarization* (macOS only) is an extra step: you upload the signed app to
  Apple, they scan it and issue a ticket you "staple" to the app. Without it,
  even a signed app gets a Gatekeeper warning on first open.
- Both require a paid developer identity. There is no free path to a build that
  opens cleanly on someone else's machine.

# macOS — what to get

1. *Apple Developer Program* — $99/yr at https://developer.apple.com/programs/.
   Required; there is no way around it for distributable signing.
2. *A "Developer ID Application" certificate* — create it in the Apple Developer
   portal (Certificates → +) or let Xcode manage it. This is the cert for apps
   distributed OUTSIDE the Mac App Store (what a shareable Tauri build is).
   Install it into your login keychain. Verify:
```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
```
3. *Notarization credentials* — the preferred path reuses an App Store Connect
   API key (.p8): set `APPLE_API_KEY` / `APPLE_API_ISSUER` / `APPLE_API_KEY_PATH`
   (see the dedicated section below). Fallback is an app-specific password
   (appleid.apple.com → Sign-In and Security → App-Specific Passwords) plus your
   Team ID — Tauri reads these env vars directly:
```bash
   export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   export APPLE_ID="you@example.com"
   export APPLE_PASSWORD="abcd-efgh-ijkl-mnop"   # app-specific, NOT your Apple ID password
   export APPLE_TEAM_ID="TEAMID"
```
   With either set, `cargo tauri build` signs and notarizes + staples
   automatically; without them it builds unsigned.

# Windows — what to get

- A *code-signing certificate* (OV or, for instant SmartScreen reputation, EV)
  from a CA like DigiCert / Sectigo. Cheaper than Apple but still paid.
- Tauri reads `TAURI_SIGNING_PRIVATE_KEY` / `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
  (for the updater) and the OS signing toolchain uses the cert thumbprint.
  Unsigned MSIs trigger SmartScreen; EV certs clear it immediately, OV certs
  build reputation over time.

# Linux

No signing required by convention — AppImage / .deb / .rpm distribute unsigned.
(Flatpak/Snap stores have their own signing; out of scope for the thin shell.)

# Workflow

```bash
# 1. see what signing identity is present (the manual "doctor")
security find-identity -v -p codesigning | grep "Developer ID Application"

# 2. (macOS) with the cert + creds exported (above), build the Tauri app —
#    Tauri signs + notarizes + staples using those env vars:
cargo tauri build           # or: npx @tauri-apps/cli build

# 3. ship the signed (+ notarized) artifact from src-tauri/target/release/bundle/
```

(Wrapping a workbook as a thin Tauri shell — scaffold a Tauri project whose
`frontendDist` points at the dir holding `dist/<slug>.html` as `index.html`, set
the app name/identifier/icon in `src-tauri/tauri.conf.json`, then build as above.
See https://v2.tauri.app/start/ for scaffolding.)

# Common pitfalls

- *App-specific password vs Apple ID password*: notarization needs the
  app-specific one. Using the account password fails with an auth error.
- *"Developer ID Application" vs "Apple Development"*: the former distributes
  outside the App Store (what you want); the latter only runs on registered
  devices. Look specifically for "Developer ID Application".
- *Team ID*: find it at the top-right of the Apple Developer portal, or
  `security find-identity` shows it in parentheses in the identity name.
- *Notarization takes minutes*: Apple's service is async; the build waits on it.
  A slow build near the end is usually notarization, not a hang.
- *Unsigned is fine for yourself*: if the user only wants the app on their OWN
  machine, skip all of this — `cargo tauri build` already works unsigned.

# Verification checklist

- `security find-identity -v -p codesigning` lists "Developer ID Application".
- After build: `codesign --verify --deep --strict <app>` exits 0.
- After notarization: `spctl -a -vv <app>` says "accepted / Notarized".
- A colleague on another Mac can open the .dmg without a Gatekeeper block.

# Notarize with an App Store Connect API key (.p8)

The same App Store Connect API key (.p8) that notarizes iOS uploads also
notarizes a desktop build — ONE key for both. Set the three Tauri env vars and
keep the .p8 where you placed it:

```bash
export APPLE_API_KEY="ABCD123456"                                   # the Key ID
export APPLE_API_ISSUER="aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"           # the Issuer ID
export APPLE_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABCD123456.p8"
```

With those present, `cargo tauri build` notarizes + staples automatically — no
app-specific password, no Apple ID. (Tauri prefers the explicit
`APPLE_API_KEY` path when set; otherwise it uses the `APPLE_ID` /
`APPLE_PASSWORD` / `APPLE_TEAM_ID` set.) Result: an artifact that is signed +
notarized + stapled + Gatekeeper-accepted (`spctl -a -vv` reports "Notarized").

# See also

- Tauri signing docs: https://v2.tauri.app/distribute/sign/
- `cargo tauri build --help` — authoritative for flags.
- `tauri cross-platform-release` — multi-target + the release-CI matrix.
