# Workbooks Mobile — the native iOS shell

The `local` provider for the mobile target: a native **SwiftUI** app that is the phone-side half of
the one Host/Dock surface. It does four things and nothing else:

1. **Authenticate** to a workbooks account and **pair** with a nexus (`POST /mobile/pair` →
   device-scoped `wbk_` token, stored in the iOS Keychain / secure enclave).
2. **Discover nexuses** — a user may belong to several orgs (one nexus per org). Each pairing adds a
   `runtime` endpoint; the launcher pools apps across all of them.
3. **Fetch the catalog** (`GET /mobile/apps`) and draw the pocket-of-apps grid — natively, off the
   same JSON the `.work` [[launcher]] island uses.
4. **Host a received app** — load its woven `client` island in a `WKWebView` and inject `window.WB`,
   the Host bridge that routes capabilities to `local` (iOS APIs) or `runtime` (the originating nexus
   over RCP/HTTP+WS). This is the Dock membrane on the phone — the UI never sees a second contract.

This is **not** a re-implementation of the cloud dashboard. It is a *receiver*: a place published
workbook apps land and run.

## Layout

| File | Role |
|------|------|
| `Sources/WorkbooksMobile/WorkbooksMobileApp.swift` | `@main` entry, root navigation |
| `Account.swift` | Multi-nexus account + Keychain-backed device tokens |
| `NexusClient.swift` | Bearer HTTP client per nexus endpoint (the `runtime` provider) |
| `AppCatalog.swift` | Catalog models + `/mobile/apps` fetch, pooled across nexuses |
| `LauncherView.swift` | Native pocket-of-apps grid |
| `AppHostView.swift` | `WKWebView` host for a received app's `client` island |
| `HostBridge.swift` | The Dock seam — `window.WB` + local↔runtime capability routing |

## Build

The project is generated with [XcodeGen](https://github.com/yonsei/XcodeGen) so the repo carries no
binary `.xcodeproj`:

```sh
brew install xcodegen
cd dogfood/mobile/shell && xcodegen generate
open WorkbooksMobile.xcodeproj   # or: xcodebuild -scheme WorkbooksMobile -sdk iphonesimulator
```

Point it at a running nexus (local: `WB_WEB=1 iex -S mix`, or your cloud nexus) on the pairing
screen.

## Swift→wasm — the other half of the loop

The shell is native Swift because the **local provider IS the OS**. Separately, Swift is registered
as a **sandbox compiler lane** in the runtime (`compilers/swift/`, `Nexus.Compilers.Swift`,
dispatched from `Nexus.Compile`): a workbook author can write a `swift` block and have it compile →
a sandboxed wasm component like `rust`/`zig`/`c`. This uses the official Swift 6.2 WebAssembly SDK
(WASI) — production-proven (two years at Goodnotes). **Honest caveat:** unlike the other lanes (whose
compilers run *inside* wasm), Swift upstream ships only a *native* `swiftc` — no wasm-hosted Swift
compiler yet — so the compile step is native host-side cross-compilation; the produced artifact still
runs sandboxed. When a wasm-hosted swiftc lands upstream the lane swaps to the in-sandbox executor
with no dispatcher change. So the device is Swift-native *and* the apps it receives can themselves be
authored in Swift. The lane needs the toolchain provisioned into `compilers/swift/`
(gitignored, like every other lane) before a cold compile can run; see
`nexus/scripts/stage-tools.sh`.
