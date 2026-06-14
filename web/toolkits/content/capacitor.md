# capacitor

Wrap a compiled workbook as a native iOS app and ship it to TestFlight. `capacitor` drives Capacitor 8.x (via `npx cap`, no global install) through the `wb forge mobile` recipes: take a built `dist/<slug>.html`, scaffold a real Capacitor iOS project around it, run it in the Simulator, archive a signed `.ipa`, and upload it to TestFlight.

## When to reach for it

Reach for `capacitor` when a workbook should ship as a native iOS app on the App Store / TestFlight. Signing and upload use the user's own Apple Developer account and an App Store Connect API key — Workbooks never holds Apple credentials.

## Example

```
wb forge mobile doctor      # check Xcode, Node/Capacitor, signing readiness
wb forge mobile dev         # run in the iOS Simulator
wb forge mobile build --export-method app-store
wb forge mobile upload      # native ASC Build Upload API — just the .p8
```

## What it grants

- `doctor` / `dev` / `build` / `upload` / `testflight` / `create-app` / `feedback` / `webhooks` / `release-init` verbs.
- Native TestFlight upload via the App Store Connect API (no Fastlane/Transporter needed).
- Automatic mobile QoL normalization (notch-safe viewport, touch tuning, safe-area, splash) — opt out with `WB_FORGE_NO_MOBILE_NORMALIZE=1`.
- Optional push entitlements with `WB_FORGE_PUSH=1` (delivery still needs your own APNs key + sender).

## Maturity

Experimental. Requires full Xcode.app (CommandLineTools can't archive or sign), Node 18+, and Capacitor 8+. Some Apple setup is genuinely one-time and manual — the `ship-a-workbook-to-ios` skill walks through all of it.
