# tauri

Wrap a compiled workbook `.html` as a thin-shell native desktop app with Tauri v2. The Workbooks use case is a thin shell: a Tauri webview pointing at a prebuilt single-file workbook (`dist/<slug>.html`) — no engine, no Node at runtime, no IPC commands. Scaffold a Tauri project whose `frontendDist` points at the workbook, then `cargo tauri build`.

## When to reach for it

Reach for `tauri` when a workbook should ship as a native desktop app for macOS / Windows / Linux. The skills cover the part agents get wrong — code signing and notarization, the gate between "builds on my machine" and "I can share it."

## Example

```
# scaffold a Tauri project, point frontendDist at dist/<slug>.html, then:
cargo tauri build                   # native installer in src-tauri/target/release/bundle/
# then sign + notarize so it's shareable (see the code-signing skill)
```

## What it grants

- A native desktop shell around a single-file workbook (no vendored engine or Node runtime).
- Cross-platform installers for macOS / Windows / Linux from one `.html`.
- Recipes for code signing + notarization (macOS) and signing (Windows).

## Maturity

Experimental (v0.1.0). Requires `cargo` and tauri-cli 2+. `cargo tauri build --help` remains authoritative for flags. For native *iOS* the decision is locked on Capacitor — see the `capacitor` toolkit.
