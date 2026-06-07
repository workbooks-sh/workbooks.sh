# Engine Track — Framework Comparison for Addendum

**Date:** 2026-06-05 (all version/status claims verified against live sources this week)
**Scope:** Lua-first comparison of LÖVE, Defold, Solar2D, plus Godot 4.x and Unity as non-Lua challengers, for a solo dev on macOS shipping a Balatro-feel, real-time, local-first 2D card game to iOS (primary) and Android.

---

## TL;DR

**Recommendation: Defold.** It is the only candidate that is simultaneously Lua-native, mobile-first, actively shipped monthly (1.12.4, May 2026), foundation-backed, and gives you **hot reload of code, art, and shaders on a physical phone** — which is exactly the iteration loop a juice-obsessed solo dev needs. Its one real gap (no built-in haptics API) is a ~100-line native extension compiled by Defold's zero-setup cloud builders.

**Runner-up: LÖVE** — maximal composability and the Balatro lineage, but its mobile pipeline is DIY (you own an Xcode project and a Gradle project), its iOS haptics are effectively nonexistent without writing Objective-C yourself, and LÖVE 12 has been "almost done" since 2023 and is still untagged in June 2026.

**Strongest non-Lua alternative: Godot 4.6** — decisively better than everything here on text rendering, editor tooling, and out-of-box haptics (`Input.vibrate_handheld` with amplitude works on iOS 13+). Choose it if the Lua requirement softens; a maintained Lua GDExtension exists but it is a niche path, not the paved road.

**Solar2D is alive but is a one-maintainer project.** Respect, but no.
**Unity is overkill and culturally wrong for this project.** Dismissed with reasons below.

---

## 1. Framework deep dives

### 1.1 LÖVE (love2d) — what Balatro uses

**Status (verified June 2026):** Latest stable is **11.5, released December 3, 2023**. LÖVE **12.0 is still unreleased** — the GitHub milestone shows 71 closed / 4 open issues, the maintainers said in April 2025 it would ship "definitely this year," and it did not. The repo itself is alive (commits as recent as June 1, 2026) and commercial games have shipped on 12.0 nightlies, but you would be choosing between a 2.5-year-old stable and a perpetual release candidate.

**What LÖVE 12 changes (relevant to us):** a **Metal backend** (macOS 10.15+/iOS 13+) and **Vulkan backend** (Windows/Linux/Android 7+), compute shaders, and opt-in GLSL 4.30 / GLSL ES 3.20. This matters because Apple has deprecated OpenGL ES; LÖVE 11.5 on iOS rides the deprecated GL stack. For a 2026-2027 iOS-first ship, you'd realistically target 12 nightlies.

**(a) Build/ship pipeline:** Entirely DIY, but documented and proven.
- *iOS:* clone the LÖVE iOS source, open `platform/xcode/love.xcodeproj`, add your `game.love` to Copy Bundle Resources, build the `love-ios` target. You own this Xcode project forever — icons, signing, plist, App Store submission are your problem (standard Xcode pain, no tooling help).
- *Android:* clone `love2d/love-android` (actively maintained — AGP 8.13.2 update Jan 2026, CMake fix Feb 2026), drop game files into `app/src/embed/assets`, edit the manifest/gradle, `./gradlew bundleEmbedNoRecordRelease` → AAB for Play Console.
- Community CI exists (**love-actions** GitHub Actions for Android/iOS/desktop builds).
- *Proof it works:* **Balatro** itself — though note the mobile port was engineered by publisher **Playstack**, not solo LocalThunk, and they added haptics and touch UI themselves. The community `balatro-mobile-maker` tool repackages the Steam build via love-android, which demonstrates the stock pipeline is genuinely functional.

**(b) Touch + haptics:** Touch via `love.touch` / `love.touchpressed` — fine. Haptics are the weak point: `love.system.vibrate(seconds)` works with duration on Android, but **on iOS it always fires a fixed 0.5-second buzz** ("due to limitations in the iOS system APIs" per the wiki — really because nobody wired up the modern API). Open issue [love2d/love#1904](https://github.com/love2d/love/issues/1904) proposes mapping to `UIImpactFeedbackGenerator`; unmerged. **To get Balatro-quality haptic ticks on iOS you must write Objective-C in your owned Xcode project** (expose UIImpactFeedbackGenerator / CHHapticEngine to Lua via the C API or a small bridge). Doable for a competent dev — it's maybe a day of work — but it is *your* code to maintain. Android: same story via JNI for `VibrationEffect`, or accept duration-only `love.system.vibrate`.

**(c) Shaders:** Excellent and famously easy — `love.graphics.newShader` with GLSL pixel/vertex shaders, render-to-canvas for post-processing chains. Balatro's CRT/foil/dissolve effects are LÖVE pixel shaders; the **moonshine** library ships ready-made CRT, scanline, glow, and chromatic-aberration passes. LÖVE 12 adds compute shaders and newer GLSL. This is the best "copy Balatro's homework" story of any framework.

**(d) Text rendering:** FreeType raster fonts; crisp at the size you bake, re-rasterize per size, no SDF text, no shaping engine. Fine for a card game with controlled type sizes; weakest of the four for dynamic scaling/internationalization.

**(e) Assets + save data:** `.love` zip fused into the app; `love.filesystem` gives a sandboxed save dir on all platforms; serialize Lua tables with `bitser`/`binser`. Perfectly local-first.

**(f) Iteration speed:** Instant launch on desktop; hot reload via community libs (`lurker`, `lick`). **No on-device hot reload** — testing haptics/touch feel means an Xcode rebuild each time. You'd develop 95% on macOS (same Lua runs everywhere) and do device passes in batches. Note: LuaJIT runs in interpreter mode on iOS (no JIT allowed by Apple) — irrelevant at card-game scale.

**(g) Ecosystem:** Small, sharp, very composable: `flux`/`tween.lua` (tweening), `hump` (timers/vectors/state), `anim8`, `batteries`, `SUIT`/`Slab` (immediate-mode UI), `moonshine` (post-fx). No editor, no scene format — everything is code, which is precisely what a composability-loving author enjoys.

**(h) License/cost:** zlib. Free, no strings.

**(i) Maintenance risk:** Medium. 18-year-old project, post-Balatro visibility, active commits — but a tiny core team, a 3-year major-release gap, and mobile platforms maintained at arm's length from the core. The framework won't die; the question is whether mobile stays first-class.

---

### 1.2 Defold — Lua-native, mobile-first

**Status (verified June 2026):** Very active: **1.12.0 (Jan 2026), 1.12.1 (Feb), … 1.12.4 (May 4, 2026)** — a sustained ~monthly cadence. Owned by the **Defold Foundation** (Swedish foundation, founded May 2020, ex-King engineering leadership on the board, two full-time engine developers funded by the foundation, corporate partners incl. King-adjacent companies). Source-available on GitHub.

**(a) Build/ship pipeline:** The best in class for this project. The editor **bundles signed iOS IPAs and Android APK/AABs directly from macOS** — no Xcode project to own, no Gradle file to maintain. iOS still requires the normal Apple ceremony (certificates, provisioning profiles, $99 dev account) but Defold's manual walks through it and the editor handles signing. Native extensions are compiled by **Defold's zero-setup cloud build servers** — you never install an NDK. Output binaries are famously tiny (empty project ≈ low single-digit MB; the HTML5 empty project is 1.06 MB as of 1.12.4).

**(b) Touch + haptics:** Multi-touch input built in (action bindings, `touch_multi`). **No built-in vibrate/haptics API** — this is Defold's one real gap for us. The path is a **native extension**: community options exist (a `Vibration` asset on the portal; a `TapticEngine` iOS extension wrapping UIImpactFeedbackGenerator — functional but old/unmaintained), and the honest plan is to write your own ~100-line extension: Obj-C calling `UIImpactFeedbackGenerator`/`CHHapticEngine` on iOS, Java calling `VibrationEffect` on Android, exposed to Lua. Because extensions build in the cloud, this is genuinely low-friction — you write the bridge once and it compiles for both platforms with no local toolchain. Budget 2–4 days including testing.

**(c) Shaders:** Full programmable pipeline: custom **materials** (GLSL vertex/fragment), a Lua **render script** controlling the whole frame (render targets, passes — post-processing CRT/foil/dissolve all achievable), and **shaders hot-reload on a running game, including on device**. Built-in particle FX editor with curve editors. The juice ceiling is high; the workflow for *tuning* juice is the best here.

**(d) Text rendering:** Bitmap and **distance-field fonts** built in, BMFont support, GUI text nodes with kerning/leading/shadow/outline. Better than LÖVE for scaled text, below Godot (no shaping engine). Fully adequate for a card game.

**(e) Assets + save data:** Everything compiles into the bundle's archive — local-first by default. `sys.save()`/`sys.load()` serialize Lua tables to platform-correct locations in one call. **Live Update** exists if you ever want post-ship content packs without store review (optional, not needed for v1, nice future lever for "new card pack" drops).

**(f) Iteration speed:** The killer feature: **hot reload on device**. Run the dev app on your iPhone, target it from the editor, and reload Lua, GUI, atlases, particle FX, and shaders into the *running game on the phone*. For a game whose core risk is "does this card flip feel juicy with haptics on glass," tuning live on the device is a categorically better loop than everyone else's rebuild-and-redeploy.

**(g) Ecosystem:** Mid-sized and healthy: **Druid** (the de-facto UI component framework — active, last pushed May 24, 2026, 560+ stars), **Monarch** (screen manager), built-in `go.animate`/`gui.animate` tweening with a full easing catalog, the official Asset Portal. Smaller than Godot's, larger and more mobile-focused than LÖVE's. One philosophical note: Defold structures games as game objects/collections with message passing — more opinionated than LÖVE's blank canvas. Pure game logic (the resonance sim, deck state) lives in plain Lua modules and stays as composable as you like; the friction is in the scene/component layer and typically lasts the first two weeks.

**(h) License/cost:** Free, no royalties, no tiers. "Defold License" = Apache 2.0 derivative whose only restriction is you can't resell the engine itself. No splash screen requirement.

**(i) Maintenance risk:** Low-medium. Foundation legal structure (objectives are locked by Swedish foundation law — the engine cannot be rugged commercially), corporate sponsorship, two full-time devs plus contributors, monthly releases, source on GitHub so a fork is always possible. Smaller bus count than Godot but structurally protected.

---

### 1.3 Solar2D (ex-Corona SDK) — alive, but…

**Status (verified June 2026):** Genuinely alive: latest release **2026.3730** (with Xcode 26.4 support; 2026.3729 shipped Feb 2026), MIT-licensed, community-maintained with **Vlad Shcherban as effectively the sole principal developer**, funded by GitHub Sponsors/Patreon.

- **(a) Pipeline:** Build for iOS/Android from the Solar2D Simulator on macOS; releases have tracked new Xcode versions promptly. Decent.
- **(b) Haptics:** `system.vibrate()` plus a free **`plugin.tapticEngine`** (Scott Harrison, hosted in the solar2d GitHub org) wrapping the iOS Taptic API, and a controller-haptics plugin that plays AHAP files. Honestly better out-of-box haptics than LÖVE or Defold.
- **(c) Shaders:** `graphics.defineEffect` custom GLSL effects per display object + snapshots. Workable, but the rendering pipeline is the least flexible of the four, and it sits on the deprecated OpenGL ES stack on iOS with no Metal migration on any public roadmap.
- **(d) Text:** Uses native OS text rendering — actually good quality.
- **(f) Iteration:** Simulator auto-relaunch on save + "Live Builds" to device — decent loop.
- **(i) Maintenance risk: HIGH.** Bus factor ≈ 1, donation-funded, plugin ecosystem aging, GL deprecation overhang. The engine deserves respect for keeping pace with Xcode releases, but betting a multi-year project on it is not responsible in 2026.

**Verdict:** eliminated on long-term risk, despite the pleasant API and the surprisingly good haptics plugin story.

---

### 1.4 Godot 4.6 — the strongest non-Lua alternative

**Status (verified June 2026):** **4.6 released January 2026; 4.6.3 maintenance release June 3, 2026**; 4.7 in development. MIT license. The largest community and lowest existential risk of anything in this document.

- **(a) Pipeline:** Android exports a signed APK/AAB directly; iOS export produces an **Xcode project** (export templates + Team ID/bundle id in the editor, then archive/submit in Xcode; a documented "link project folder into Xcode" workflow avoids re-exporting during development). One-click deploy to device with remote debug. iOS *simulator* export is unsupported (GH-102149), but Apple Silicon Macs run the iOS build natively. More ceremony than Defold, less than LÖVE.
- **(b) Haptics: best out-of-box.** `Input.vibrate_handheld(duration_ms, amplitude)` is implemented on **Android, iOS (13+), and Web**, with amplitude control — built into core, no plugin. Community plugins (e.g. `kyoz/godot-haptics`) add UIImpactFeedbackGenerator-style discrete ticks if you want them.
- **(c) Shaders:** `canvas_item` shader language (thin GLSL dialect), full post-processing, and **godotshaders.com is full of ready-made Balatro-style foil/holographic/CRT/dissolve shaders**. Excellent.
- **(d) Text: decisively the best** — HarfBuzz shaping, MSDF fonts (crisp at any scale), RichTextLabel with BBCode effects (wave, shake, rainbow — free juice for numbers/labels), emoji, fallback chains.
- **(e) Local-first:** PCK packaging, `user://` storage, `ConfigFile`/JSON. Fine.
- **(f) Iteration:** GDScript hot-reload in editor, live scene editing, one-click device deploy. Very good, though device iteration is still deploy-based, not Defold-style live-patching of a running phone build.
- **(g) Ecosystem:** Enormous. Built-in Tween (the modern `create_tween()` API is genuinely pleasant), GPUParticles2D, AnimationPlayer; card-game frameworks exist (e.g. godot-card-game-framework). Real shipped comparable: **Luck be a Landlord** (solo dev, deckbuilder, Godot, shipped iOS + Android).
- **Lua story:** `gilzoide/lua-gdextension` (v0.8.1, May 17, 2026; actively pushed May 30, 2026) scripts Godot objects in Lua 5.4 or LuaJIT and ships an iOS xcframework — real, maintained, and impressive, but it is one maintainer's project layered on a GDScript-first engine. Honest framing: **if you choose Godot, plan to write GDScript** (Python-ish, signal-based, hot-reloadable — composable in practice, just not Lua).
- **(h) Cost:** Free, MIT. **(i) Risk:** lowest here.
- **Cons for us:** export binaries ~40+ MB vs Defold's few MB (irrelevant to players in 2026, mildly inelegant); node/scene architecture is the most "engine-shaped" of the candidates; the editor-centric workflow is the furthest from LÖVE-style code-first composability.

### 1.5 Unity — dismissed, with reasons

Runtime Fee cancelled September 2024; Unity Personal is free under $200k revenue/funding, Pro ≈ $2,040–2,400/seat/yr with a 5% increase from January 12, 2026. Lua is third-party only (xLua/MoonSharp — modding-oriented, unmaintained energy). For a solo 2D card game it brings IL2CPP build times, a proprietary license, demonstrated pricing whiplash, and zero Lua affinity. **No axis where it is decisively better for this project.** Eliminated.

---

## 2. Comparison matrix

| Axis | LÖVE 11.5/12-nightly | **Defold 1.12.4** | Solar2D 2026.3730 | Godot 4.6.3 |
|---|---|---|---|---|
| (a) iOS+Android ship from macOS | DIY Xcode + Gradle projects (proven by Balatro, but you own them) | **Editor bundles signed IPA/AAB; cloud-built extensions** | Simulator builds both; keeps pace with Xcode | Android direct; iOS via exported Xcode project |
| (b) Native haptics | iOS: fixed 0.5 s buzz; real haptics = write Obj-C yourself | No core API; small native extension (cloud-built) — 2–4 days | `plugin.tapticEngine` + AHAP controller plugin (best stock Lua option) | **`vibrate_handheld` w/ amplitude built in (iOS 13+/Android); plugins for ticks** |
| (c) Shaders (CRT/foil/dissolve) | **Excellent — Balatro's own recipe; moonshine; 12 = Metal/compute** | Excellent — materials + Lua render script; **shaders hot-reload on device** | OK — per-object effects; GL ES deprecation risk | Excellent — canvas shaders + huge shader library |
| (d) Text | Raster only, per-size | SDF + bitmap, good | Native OS text | **HarfBuzz + MSDF + RichText effects — best** |
| (e) Local-first packaging/saves | `.love` fused; `love.filesystem` | Archive in bundle; `sys.save/load`; optional Live Update | Bundled; docs dir + JSON | PCK; `user://` |
| (f) Iteration | Instant desktop; device = rebuild | **Hot reload code/art/shaders ON DEVICE** | Sim auto-reload; Live Builds | Editor hot-reload; 1-click deploy |
| (g) Ecosystem | Small, sharp, code-first (flux, hump, anim8, moonshine) | Mid, mobile-focused (Druid, Monarch, go.animate) | Aging | **Huge** (Tween, particles, card frameworks) |
| (h) License | zlib, free | Apache-derived, free, no royalties | MIT, free | MIT, free |
| (i) Maintenance risk | Medium (slow majors, small team) | **Low-med (foundation, monthly releases)** | **High (bus factor 1)** | Lowest (huge community) |
| Lua | **Pure Lua, blank canvas** | **Lua-native (LuaJIT)** | Lua | GDScript (Lua via maintained but niche GDExtension) |

---

## 3. Recommendation

### Primary: **Defold**

For *this* author and *this* game, Defold wins on the intersection that matters:

1. **Mobile-first is not a port target — it's the default.** One editor on macOS produces signed store artifacts for both platforms. As a solo dev you cannot afford to be your own porting house (Balatro needed Playstack's engineers for its mobile port).
2. **The core gameplay risk is feel, and feel is tuned on glass.** Defold is the only candidate where you change a tween curve, a particle emitter, a shader uniform, or a haptic call and see/feel it **in the running game on your iPhone** without a rebuild. For a "watch the ad perform live" real-time dashboard game, this iteration loop compounds daily.
3. **Lua all the way down**, with your simulation (resonance patterns, fatigue decay, metrics) in plain, framework-free Lua modules — portable, testable, composable. Treat Defold's GO/message layer as the shell, not the brain.
4. **Sustainable without a vendor.** Foundation-owned, source-available, free, monthly releases, legally cannot be commercialized out from under you.

Accepted costs: write one small haptics native extension (iOS Core Haptics / UIImpactFeedbackGenerator + Android VibrationEffect — cloud-built, do it in week one to de-risk); accept the message-passing architecture (annoying for ~2 weeks, then fine); a smaller ecosystem than Godot's.

### Runner-up: **LÖVE**

Choose LÖVE instead if, after a 1-week Defold spike, the collection/message-passing structure genuinely fights your composability instincts. You get the Balatro recipe verbatim and total code-first freedom. Eyes open about the price: you own an Xcode project and a Gradle project for the life of the product; you write the iOS haptics bridge in Objective-C yourself; you ship on 11.5 (deprecated GL on iOS) or a 12 nightly (unreleased after 2.5 years); and on-device iteration is rebuild-based. Budget 2–4 extra weeks of platform plumbing before the first device build feels good.

### Escape hatch: **Godot 4.6**

If the Lua requirement ever softens, Godot is decisively better on text rendering, editor tooling, built-in haptics, and ecosystem depth, with the lowest long-term risk — Luck be a Landlord proves the exact solo-dev-deckbuilder-to-mobile path. Do not choose it *for* the Lua GDExtension; choose it only if GDScript is acceptable.

### De-risking plan (recommended first sprint)

1. Defold spike, 5 days: one draggable card with squash/stretch tween, a foil shader, a particle burst, SDF text, and a custom haptics extension firing `UIImpactFeedbackGenerator` ticks — hot-reloaded live on an iPhone.
2. Same spike in LÖVE on desktop in 2 days (it will be faster to write), then attempt the iOS device build + haptic bridge (this is where the difference will show).
3. Decide. The simulation core you write in plain Lua during these spikes carries over either way — make that separation a hard architectural rule from day one.

---

## Sources

- LÖVE releases (11.5 latest stable): https://github.com/love2d/love/releases
- LÖVE 12.0 milestone (71 closed / 4 open, June 2026): https://github.com/love2d/love/milestone/1
- LÖVE 12 release-timeline forum thread ("definitely this year," Apr 2025): https://love2d.org/forums/viewtopic.php?t=96418
- LÖVE 12.0 changelog (Metal/Vulkan/compute): https://love2d.org/wiki/12.0
- Metal backend PR: https://github.com/love2d/love/pull/1761
- LÖVE Game Distribution (iOS/Android workflows): https://love2d.org/wiki/Game_Distribution
- love-android repo (active Jan–Feb 2026): https://github.com/love2d/love-android
- love.system.vibrate (iOS fixed 0.5 s): https://love2d.org/wiki/love.system.vibrate
- iOS haptics feature request (#1904): https://github.com/love2d/love/issues/1904
- love-actions CI: https://github.com/love-actions
- balatro-mobile-maker (stock pipeline proof): https://github.com/blake502/balatro-mobile-maker
- Balatro (LÖVE; Playstack mobile port, Sept 26 2024): https://en.wikipedia.org/wiki/Balatro
- Defold 1.12.0: https://defold.com/2026/01/12/Defold-1-12-0/
- Defold 1.12.4 (May 4, 2026): https://defold.com/2026/05/04/Defold-1-12-4/
- Defold iOS manual (Mac-only bundling, signing): https://defold.com/manuals/ios/
- Defold hot reload (incl. on device + shaders): https://defold.com/manuals/hot-reload/
- Defold native extensions (cloud builders): https://defold.com/manuals/extensions/
- Defold haptics forum thread: https://forum.defold.com/t/haptic-vibration-for-mobile/75863
- Defold TapticEngine extension: https://forum.defold.com/t/tapticengine-native-extension-for-ios-taptic-engine/57279
- Defold Vibration asset: https://defold.com/assets/vibration/
- Defold License: https://defold.com/license/
- Defold Foundation: https://defold.com/foundation/
- Druid UI framework (active May 2026): https://github.com/Insality/druid
- Solar2D repo/releases (2026.3730): https://github.com/coronalabs/corona/releases
- Solar2D site: https://solar2d.com/
- Solar2D free plugins: https://plugins.solar2d.com/
- Solar2D tapticEngine plugin: https://github.com/solar2d/tech.scotth-plugin.tapticEngine
- Solar2D controller-haptics/AHAP plugin thread: https://forums.solar2d.com/t/new-charts-plugin-and-controller-haptic-plugin/354818
- Godot 4.6 release: https://godotengine.org/releases/4.6/
- Godot 4.6.2 maintenance: https://godotengine.org/article/maintenance-release-godot-4-6-2/
- Godot Input.vibrate_handheld (Android/iOS/Web, amplitude): https://docs.godotengine.org/en/stable/classes/class_input.html
- Godot iOS export: https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html
- lua-gdextension (0.8.1, May 2026, iOS xcframework): https://github.com/gilzoide/lua-gdextension
- godot-haptics plugin: https://github.com/kyoz/godot-haptics
- Unity Runtime Fee cancellation: https://unity.com/blog/unity-is-canceling-the-runtime-fee
- Unity pricing changes (5% Pro increase Jan 12, 2026): https://unity.com/products/pricing-updates
