# capacitor

Wrap a compiled workbook as a native iOS app and ship it to TestFlight. `capacitor` drives Capacitor 8.x (via `npx cap`, no global install): take a built `dist/<slug>.html`, scaffold a real Capacitor iOS project around it, run it in the Simulator, archive + sign it in Xcode, and upload it to TestFlight.

## When to reach for it

Reach for `capacitor` when a workbook should ship as a native iOS app on the App Store / TestFlight. This is a host-side workflow — it needs a Mac with full Xcode. Signing and upload use the user's own Apple Developer account and an App Store Connect API key — Workbooks never holds Apple credentials.

## Example

```
npx cap add ios            # scaffold the native iOS project (once)
npx cap copy ios           # stage the workbook's www/index.html into the app
npx cap run ios            # run in the iOS Simulator (no Apple account)
npx cap open ios           # open in Xcode → Archive → Distribute → TestFlight
```

## What it grants

- The real `npx cap` flow (`add` / `copy` / `sync` / `open` / `run`) to wrap and run a workbook as a native iOS app.
- A clear path through Xcode (Product → Archive → Distribute App) for signing and TestFlight upload — via the Xcode Organizer, the Transporter app, or `xcrun altool` with your App Store Connect `.p8`.
- A walkthrough of the one-time Apple Developer / App Store Connect setup (program, agreements, app record, API key) and the common gotchas (CommandLineTools vs full Xcode, the 90129 display-name collision).

## Maturity

Experimental. Requires full Xcode.app (CommandLineTools can't archive or sign), Node 18+, and Capacitor 8+. There is no `work forge mobile` command — the toolkit is grounded on `npx cap` + Xcode directly. Some Apple setup is genuinely one-time and manual — the `ship-a-workbook-to-ios` skill walks through all of it.
