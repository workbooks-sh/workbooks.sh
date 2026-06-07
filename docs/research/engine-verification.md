# Engine recommendation — adversarial verification record

Date: 2026-06-05. Method: two independent skeptic agents were instructed to **refute** the Defold recommendation (docs/research/engine.md) using live web research, with "default to refuted if uncertain." Both returned `refuted: false` at **high confidence**. This file preserves their findings so DECISIONS.md's claims are checkable in-repo.

## Skeptic 1 — shipping & maintenance reality

**Verdict: not refuted (high confidence).**

- **Store-compliance posture (the decisive test):** Apple has required Xcode 26 / iOS 26 SDK for all App Store uploads since April 28, 2026. Defold 1.12.1 (Feb 4, 2026) shipped Xcode 26.2 / iOS SDK 26.2 support nearly three months early, and the same release bumped Android `targetSdkVersion` to 36 — seven months ahead of Google Play's Aug 31, 2026 deadline (verified via defold/defold issue #11553 and the 1.12.1 release notes; no post-deadline submission failures on the Defold forum). With LÖVE, the developer owns the forked Xcode/Gradle projects and that SDK-deadline treadmill personally.
- **Cadence claims check out live:** 1.12.0 Jan → 1.12.1 Feb → 1.12.2 Mar → 1.12.4 May 4, 2026.
- **LÖVE 12 ("Bestest Friend") remains unreleased** as of June 2026; stable is 11.5 (Dec 2023, deprecated GL on iOS). Godot fails the stated Lua constraint and ships far larger binaries.
- **Genuine weakness found (mitigated, tracked):** the haptics native extension makes every build depend on Defold's free cloud extender (build.defold.com), which has had transient errors. Mitigations: infrastructure overhauled Sept 2024 (AWS→GCP), public status page, documented self-hosted Docker fallback (extender-local-setup), and source-available Apache-derived licensing caps the worst case. **Action adopted:** stand up the local extender Docker image during the week-one haptics spike.
- Residual notes: small foundation core team (demonstrably healthier than Solar2D's bus-factor-1); 1.12.1 raised Defold's iOS minimum to 15.0 (harmless — strictly contains the planned iOS 13+ haptics floor).

## Skeptic 2 — capability gaps for this specific game

**Verdict: not refuted (high confidence).**

- **Haptics:** the recommendation's one admitted gap is overstated as a risk — community extensions already exist (def_taptic_engine for iOS Taptic; the "Vibration" portal asset for iOS+Android), so the 2–4 day custom-extension budget is conservative.
- **Audio (the gap the completeness critic flagged as never assessed — closed here):** Balatro's signature juice includes pitch-coupled music/speed ramping. Defold's sound component exposes runtime-settable **gain/pan/speed (range 0–50) via `go.set` on a playing sound**, plus group mixing, streaming, and RMS analysis — functionally equivalent to LÖVE's `Source:setPitch`. No built-in DSP effects, but the design needs none; OpenAL/FMOD extensions exist.
- **Shaders:** full GLSL materials + render-script render targets cover CRT/foil/post-fx; shader hot reload on a physical device is documented (caveat: a crashing shader kills the engine — annoying, not blocking).
- **Text:** SDF/bitmap limitation honestly disclosed and irrelevant to a numbers-and-labels card UI; defold-richtext exists.
- **Sim perf:** LuaJIT runs interpreter-only on iOS for ALL engines (Apple bans JIT); Balatro itself ships interpreted Lua on phones — trivial at card-sim scale.
- **Strongest surviving attack (tracked, not blocking):** defold#8571 — subtle iOS frame stutter during touch input, open since Feb 2024, unassigned. It targets exactly the card-drag feel this game lives on. It fails as a refutation because the issue reporter notes Godot has the identical bug (godotengine#76425), there's no evidence LÖVE avoids it, and the Phase 0b spike (draggable card on an iPhone) surfaces it before any commitment.

## Standing actions from this verification

1. Local extender Docker during week-one haptics work (single-point-of-failure insurance).
2. Phase 0b spike explicitly watches for defold#8571 stutter on device.
3. Audio juice (speed/pitch ramping, stem crossfades) is confirmed feasible — no design constraint needed.
