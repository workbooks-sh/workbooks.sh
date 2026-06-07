# Mobile UX Research: Touch, Haptics, Data-Feel & Performance

**Track:** mobileux | **Date:** 2026-06-05 | **Status:** Research complete, opinions included
**For:** Addendum — a mobile-first, local-first, real-time card game about creative strategy / paid media

This document is written as a **feel-spec**: concrete numbers a designer/engineer can implement against. Opinionated defaults are marked **[SPEC]**. Confidence is flagged where claims are version- or research-sensitive.

---

## 1. Card Interaction Ergonomics

### 1.1 How people actually hold phones

Steven Hoober's observational research (1,300+ people, still the canonical dataset) found:

- **49%** hold and operate the phone with **one hand** (thumb does everything)
- **36%** cradle in one hand, tap with the other's finger/thumb
- **15%** two-handed "BlackBerry prayer" (both thumbs)
- **~75% of all touches are thumbs**; of one-handed users, 67% use the right thumb

Sources: [Smashing Magazine — The Thumb Zone](https://www.smashingmagazine.com/2016/09/the-thumb-zone-designing-for-mobile-users/), [A List Apart — How We Hold Our Gadgets](https://alistapart.com/article/how-we-hold-our-gadgets/). Confidence: **high** (old data, but no newer study has displaced it; phones got bigger, which makes the thumb-zone constraint *stronger*).

**Implication:** the thumb-comfort zone is the **bottom-center arc** of the screen. Top corners are the hardest to reach. On 6.1–6.9" phones, roughly the top 40% of a portrait screen is outside comfortable one-handed reach.

**[SPEC] Orientation: portrait, one-handed-first.**
- Marvel Snap is portrait and it is the single biggest reason it feels like "a game you play while holding a coffee." Balatro mobile shipped **landscape-only** (Sept 2024, update 1.0.1j — "overhauled UI for touchscreens"; players publicly beg for portrait — see [Balatro Wiki Updates](https://balatrowiki.org/w/Updates)). Confidence on Balatro still lacking portrait as of latest checks: **medium** — verify in-app before citing publicly.
- For a "live manager" game you want session glue: portrait = playable on the couch, in line, one thumb. This is a strategic choice, not a styling choice. It constrains the card fan, the metric dashboard, and the slot layout — decide it **first**.

**[SPEC] Screen zoning (portrait):**
- **Bottom 25%:** the hand/card fan. Always.
- **Middle 35–40%:** the "table" — ad slots, live campaign area. Drop targets live here, biased low.
- **Top 30–35%:** read-only live metrics (glanceable, never tap-critical). Anything tappable up top must be non-time-critical (settings, deep-dive drill-ins).
- Never put a time-critical button in the top fifth of the screen.

### 1.2 Hit targets

- **Apple HIG:** 44×44 pt minimum.
- **Material Design:** 48×48 dp minimum (visual icon can be 24 dp inside the 48 dp target).
- **WCAG 2.2:** 2.5.8 (AA) = 24×24 CSS px minimum with spacing; 2.5.5 (AAA) = 44×44.

Source: [LogRocket — accessible touch target sizes](https://blog.logrocket.com/ux-design/all-accessible-touch-target-sizes/). Confidence: **high**.

**[SPEC] For cards specifically:**
- Card at rest in fan: visible sliver may be narrow, but **effective touch target ≥ 48 dp wide** — overlap the invisible hitboxes and resolve ties to the **topmost/centered** card under the touch.
- Buttons that fire during live play (boost, pause, swap creative): **≥ 56 dp**, because the player is glancing at metrics, not at the button.
- Inter-target spacing ≥ 8 dp; for destructive actions (kill ad) ≥ 16 dp from anything else.
- **Cautionary tale — Slay the Spire on Android:** "a thumb isn't a mouse cursor"; finicky card grab hitboxes, accidental plays when fingers brushed the screen edge, tiny relic/status icons that take several tries to tap ([Android Central review](https://www.androidcentral.com/slay-spire-android-game-week)). A desktop-information-density UI ported to phone is the #1 failure mode for this genre. Design at phone density from day one.

### 1.3 Drag vs tap-to-select vs tap-to-slot

What the reference games do:

- **Balatro mobile:** hybrid. **Tap to select** cards (toggle, with action buttons), **hold-and-drag** to contextual action zones that appear while dragging (sell/use/buy zones materialize on drag start). The community liked it enough to back-port it to PC as a mod ([MobileLikeDragging](https://github.com/jfmmm/BalatroMobileLikeDragging)). Drag is also used to **reorder** the hand.
- **Marvel Snap:** pure **drag from hand to location**, with three huge drop zones, generous snapping, and snap-back on release. Press lifts the card **above the finger** so it's never occluded; long-press anywhere reads a card. Interactables biased to the bottom half ([Marvel Snap UX analyses](https://curaxuan.com/game-ux-marvel-snap-ux-redesign/), [gameplay wireframe](https://medium.com/@carol.michelon/marvel-snap-gameplay-wireframe-ed76251eebc5)).
- **Hearthstone mobile:** drag-to-board, but its density problems on phones are well documented; it survives on tablet.

**[SPEC] Addendum interaction model — "tap to inspect, drag to commit":**
1. **Tap** a card in the fan → it pops up (lifts ~40% of card height, scales ~1.15×), shows full stats. Tap again or tap elsewhere → returns. Tapping is *always safe* — it never spends/plays anything. (This directly fixes the Slay the Spire mobile complaint.)
2. **Drag** = commitment. Drag a card out of the fan → drop zones (ad slots) illuminate, everything else dims 20%. Card renders **60–80 pt above the touch point** so the thumb never hides it (the Marvel Snap lift).
3. **Magnetic snapping:** when card center enters within ~64 dp of a slot center, the card visibly "leans" toward the slot and the slot pre-highlights; release inside the zone completes with a snap animation (≤120 ms, slight overshoot ease). Release outside any zone → snap-back to fan (~250 ms spring), zero penalty.
4. **Tap-to-slot as accessibility fallback:** with a card selected, tapping a highlighted slot also plays it. Costs nothing to support, rescues motor-impaired and bumpy-bus play. Ship it behind the same code path.
5. **No long-press as a primary verb.** Long-press is undiscoverable and slow; reserve it for an optional "deep inspect" duplicate of tap.

Rationale: drag is the *juicy* verb (it earns the pickup/snap haptics, it feels like committing budget), tap is the *safe* verb. Balatro mobile and Marvel Snap converge on exactly this split from opposite directions.

### 1.4 Gesture conflicts with system edges

Real-time play means accidental Home swipes are a run-killer.

- **iOS:** override `preferredScreenEdgesDeferringSystemGestures` (return `.bottom`, possibly `.all` during live rounds) so the first edge swipe goes to your game and shows the system arrow instead of exiting ([Apple docs](https://developer.apple.com/documentation/uikit/uiviewcontroller/2887512-preferredscreenedgesdeferringsys), [Use Your Loaf](https://useyourloaf.com/blog/avoiding-conflicts-with-system-gestures-at-screen-edges/)). Note: you can defer, not disable. Also respect the home-indicator safe area inset — the card fan must sit **above** it.
- **Android (10+ gesture nav):** `View.setSystemGestureExclusionRects()` to claim left/right edge strips — but the system caps exclusions (200 dp per edge) and **the bottom edge can never be excluded** ([Android gesture-nav guide](https://developer.android.com/develop/ui/views/touch-and-input/gestures/gesturenav)). Confidence: **high** on the API, **medium** on the exact 200 dp cap—verify at implementation.
- **[SPEC]** Keep the card fan's *touch-down* origin ≥ 16 dp above the bottom system inset; never require a drag that *starts* at a screen edge; defer bottom-edge gestures during rounds on iOS; on Android rely on layout (insets) rather than exclusion rects for the bottom.

---

## 2. Haptics Design Language

### 2.1 The platform vocabulary you're building on

**iOS — two tiers:**

1. **`UIFeedbackGenerator`** (cheap, semantic): `UIImpactFeedbackGenerator` with styles `.light` / `.medium` / `.heavy` / `.soft` / `.rigid` (soft/rigid since iOS 13), plus `impactOccurred(intensity: 0.0–1.0)`; `UISelectionFeedbackGenerator` (the picker-wheel tick); `UINotificationFeedbackGenerator` (`.success` / `.warning` / `.error`). Call `prepare()` ~1 s before expected use to spin up the Taptic Engine and cut latency. ([Sarunw guide](https://sarunw.com/posts/play-haptic-feedback-using-uifeedbackgenerator/), [Apple docs](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/feedbackstyle/soft))
2. **Core Haptics** (full control): patterns of `CHHapticEvent`s, each **`.hapticTransient`** (a tick/impact) or **`.hapticContinuous`** (a rumble, max 30 s), with two axes:
   - **Intensity** 0–1 — strength
   - **Sharpness** 0–1 — low = round/organic/thuddy, high = precise/crisp/mechanical
   Patterns can be authored as **AHAP** JSON files, can carry **parameter curves** (e.g., ramp intensity over time), and can embed **synchronized audio events** ([Core Haptics docs](https://developer.apple.com/documentation/corehaptics), [WWDC19 "Introducing Core Haptics"](https://developer.apple.com/videos/play/wwdc2019/520/), [Lofelt's 10 things about Core Haptics](https://medium.com/lofelt/10-things-you-should-know-about-designing-for-apple-core-haptics-9219fdebdcaa)).

**Android — `VibrationEffect.Composition` primitives** (the only path to iOS-quality feel):

| Primitive | Feel | Notes |
|---|---|---|
| `PRIMITIVE_CLICK` | strong crisp click | confirmations |
| `PRIMITIVE_TICK` | light quick tick | frequent feedback |
| `PRIMITIVE_LOW_TICK` | softest tick | metric ticks, drag texture |
| `PRIMITIVE_THUD` | heavy reverberating impact | collisions, fails |
| `PRIMITIVE_SPIN` | wobbly rotation | elastic/bounce effects |
| `PRIMITIVE_QUICK_RISE` / `SLOW_RISE` | amplitude crescendo | launches, charge-ups |
| `PRIMITIVE_QUICK_FALL` | diminuendo | releases, decays |

Each takes a **scale 0.0–1.0** (0.0 = minimum perceivable, *not* off) and an optional delay. Google's guidance: use ~3 intensity levels (e.g. **0.5 / 0.7 / 1.0**), keep scale ratios ≥ **1.4×** apart to be distinguishable, ≥ 50 ms between primitives for a perceivable gap ([custom haptic effects](https://developer.android.com/develop/ui/views/haptics/custom-haptic-effects), [haptics principles](https://developer.android.com/develop/ui/views/haptics/haptics-principles)). Composition API arrived in API 30; `LOW_TICK`/`THUD`/`SPIN` in API 31 (confidence **medium** on exact split — check `areAllPrimitivesSupported` regardless).

**Android fragmentation is the real cost.** If *any* primitive in a composition is unsupported, **the whole composition plays nothing** — you must check `vibrator.areAllPrimitivesSupported(...)` / `arePrimitivesSupported(...)` and `hasAmplitudeControl()`, and ship **three capability tiers**: (1) full primitives, (2) amplitude-controlled waveforms (`createWaveform` with amplitude arrays), (3) on/off timing patterns ([haptics APIs](https://developer.android.com/develop/ui/views/haptics/haptics-apis)). Budget real testing time on a Pixel (best actuator), a Samsung mid-ranger, and one cheap device.

### 2.2 [SPEC] Addendum haptic vocabulary

Design principles (Apple's WWDC19 framing — **causality, harmony, utility**: haptics must feel caused by the event, agree with audio/visual, and carry meaning — [Designing Audio-Haptic Experiences](https://developer.apple.com/videos/play/wwdc2019/810/)):

- **Three loudness classes.** Whisper (constant feedback), Voice (state changes), Shout (rare payoffs). If everything vibrates hard, nothing does. Marvel Snap's haptics work because they're "meticulous" and scale from "a sharp but gentle tap" to "a thunderous boom when a card slammed down" ([XDA on Marvel Snap haptics](https://www.xda-developers.com/marvel-snap-mobile-game-haptics/)).
- **Rate limit:** ≥ 80–100 ms between whisper-class events; coalesce metric ticks. Shout-class ≤ 1 per ~10 s of play, or it stops being a jackpot.
- **Global toggle + intensity slider** in settings (Marvel Snap ships a haptics toggle; so should we), and respect iOS System Haptics / Android user vibration settings.

| Event | Feel intent | iOS Core Haptics (intensity, sharpness) | iOS simple fallback | Android primitives | Android floor fallback |
|---|---|---|---|---|---|
| **Card pickup** (drag start) | light grab, "it's in your hand" | transient i 0.55 s 0.45 | impact `.soft`, intensity 0.6 | `TICK` @ 0.6 | 15 ms one-shot, amp 120/255 |
| **Card hover over slot** | gentle detent, "you're aligned" | transient i 0.3 s 0.8 | `UISelectionFeedbackGenerator` | `LOW_TICK` @ 0.5 | skip (silence beats mush) |
| **Slot snap** (card seats) | crisp mechanical click-home | transient i 0.8 s 0.7 | impact `.rigid`, intensity 0.8 | `CLICK` @ 0.7 | 25 ms, amp 200/255 |
| **Ad launch** (campaign goes live) | charge-up → release; the "pull the lever" moment | continuous 250 ms, intensity curve 0.3→0.9, s 0.4; then transient i 1.0 s 0.6 | impact `.heavy` after a 200 ms animation windup | `SLOW_RISE` @ 0.8 + `CLICK` @ 1.0 (delay 0) | waveform [0,60,40,80,30] amp ramp [60,120,180,255] |
| **Metric tick-up** (live counter increments) | typewriter whisper; scale with magnitude | transient i 0.2–0.35 s 0.9, ≥ 80 ms apart, max ~8/s | none (too chatty for UIFeedbackGenerator) | `LOW_TICK` @ 0.35–0.5 | skip |
| **ROAS jackpot** (winner pops off) | slot-machine payoff; ~700 ms set piece | transients i 0.5/0.7/0.9 s 0.6 at 0/90/180 ms + continuous 400 ms i 0.8→0.2 s 0.3 + final transient i 1.0 s 0.8 | notification `.success` + impact `.heavy` | `QUICK_RISE` @ 0.8 + 3× `TICK` @ 0.6 (80 ms apart) + `THUD` @ 1.0 | waveform [0,50,50,50,50,200] amp [255,0,180,0,255] |
| **Fatigue warning** (winner decaying) | dull double-knock, organic, "something's wrong but not urgent" | 2× transient i 0.5 s 0.15, 120 ms apart | notification `.warning` | 2× `LOW_TICK` @ 0.7, 120 ms apart | `EFFECT_DOUBLE_CLICK` predefined |
| **Round fail / account churn** | single heavy dead thud + sag | transient i 1.0 s 0.05 + continuous 300 ms i 0.4→0 s 0.1 | notification `.error` | `THUD` @ 1.0 + `QUICK_FALL` @ 0.6 | 120 ms one-shot, amp 255 |
| **Hand fan scroll** (browsing deck) | picker-wheel detents per card | transient i 0.25 s 0.85 per card boundary | `UISelectionFeedbackGenerator` | `LOW_TICK` @ 0.4 | skip |
| **Card acquired** (new card to collection) | bright, sharp, ascending pair | transients i 0.6 s 0.7 then i 0.9 s 0.9, 100 ms apart | notification `.success` | `TICK` @ 0.6 + `CLICK` @ 0.9 | 2×20 ms, 80 ms gap |

All intensity/sharpness values are **starting points to tune on hardware** — the iPhone actuator makes sharpness < 0.2 feel muddy and > 0.9 feel thin; tune in 0.05 steps. AHAP files for the multi-part patterns (launch, jackpot, fail) so design can iterate without code changes.

### 2.3 How Lua frameworks reach these APIs

This is a **framework-selection-grade finding**:

- **LÖVE (Balatro's engine):** `love.system.vibrate(seconds)` exists for Android and iOS, but on iOS it has been effectively a fixed/basic buzz; richer iOS haptics is **still an open issue** ([#1904, open](https://github.com/love2d/love/issues/1904)) with an **unmerged PR** ([#2247](https://github.com/love2d/love/pull/2247), Nov 2025, duration-based via `CHHapticEngine`, awaiting review). Latest stable is still **11.5 (Dec 2023)**; 12.0 unreleased as of this check ([releases](https://github.com/love2d/love/releases)). LÖVE has **no plugin system** — to get UIFeedbackGenerator/Core Haptics-class feedback you fork the iOS Xcode project and add an Obj-C bridge exposed to Lua (Balatro's mobile port is precedent that custom LÖVE iOS builds ship fine, but it's your fork to maintain). Effort: ~2–4 days for a competent native dev to wrap the full vocabulary above; the maintenance burden is the real cost. Confidence: **high**.
- **Defold:** first-class **native extensions**. Existing assets: [extension-vibrate](https://github.com/adamwestman/extension-vibrate) (iOS+Android, basic vibrate, last updated 2018) and [def_taptic_engine](https://github.com/MaratGilyazov/def_taptic_engine) (iOS, wraps UIFeedbackGenerator: `impact(LIGHT/MEDIUM/HEAVY)`, `notification(SUCCESS/WARNING/ERROR)`, `selection()`, `isSupported()` — 2019, unmaintained). Both are stale ([Defold forum confirms no maintained option, Jan 2024](https://forum.defold.com/t/haptic-vibration-for-mobile/75863)) but Defold's NE system makes writing a fresh ~300-line extension covering Core Haptics + VibrationEffect straightforward and *supported* — no engine fork. Confidence: **high**.
- **Solar2D:** **best out-of-the-box Lua story.** Built-in `system.vibrate([type, style])` supports `"impact"` (`light/medium/heavy`), `"selection"`, and `"notification"` (`success/warning/error`) on iOS **and Android** since build 2021.3660, with haptics fixes landing as recently as release 2025.3718 ([docs](https://docs.coronalabs.com/api/library/system/vibrate.html), [release 3718](https://github.com/coronalabs/corona/releases/tag/3718)). That covers ~70% of the vocabulary table's "simple fallback" column with zero native code; Core-Haptics-level patterns would still need a native plugin. Confidence: **high**.
- (Non-Lua reference: Unity/Godot have mature haptics assets, but that trades away the requested composability.)

**[SPEC] Recommendation:** whichever framework wins, isolate haptics behind a Lua module `haptic.play("slot_snap")` with the event names above, so the native layer is swappable and designers tune a data table, not call sites.

### 2.4 Sound + haptic sync (the "juice" multiplier)

- Apple's guidance: the magic is **synchronization** of visual+audio+haptic; latency between them "breaks the illusion completely" ([WWDC19 810](https://developer.apple.com/videos/play/wwdc2019/810/), [WWDC21 Practice audio haptic design](https://developer.apple.com/videos/play/wwdc2021/10278/)).
- Perceptual budget: audio-haptic asynchrony around **12 ms is already detectable**; measured Android system offset averages ~16 ms (audio late) ([arXiv driving-context study](https://arxiv.org/pdf/2307.05451)). Android continuous audio output latency target is ≤ 45 ms but real devices vary wildly ([AOSP audio latency](https://source.android.com/docs/core/audio/latency/latency)).
- **iOS:** for shout-class moments (launch, jackpot, fail), author AHAP patterns with **embedded audio events** (`registerAudioResource`) — Core Haptics schedules audio and haptic on the same clock, giving you sample-accurate sync for free.
- **Android:** fire the haptic from the same callback that posts the sound, and accept ~10–20 ms slop; use short percussive sounds (transient-heavy SFX hide asynchrony better than tonal ones). Android 12's `HapticGenerator` (auto-derives haptics from the audio stream) exists but device support is sparse — treat as a bonus, not the plan ([Android 12 haptics features](https://thomas--mcguire.medium.com/exploring-new-haptics-features-in-android-12-27844dba9635)). Confidence: **medium** on HapticGenerator device coverage.
- **[SPEC]** Every shout-class event = one animation keyframe + one transient SFX + one haptic, all triggered off the same frame. Never let the haptic lead the visual; if you must desync, visual first, haptic ≤ 1 frame later.

---

## 3. Live Data on Small Screens

The player is *watching an ad perform in real time* — the dashboard IS the gameplay camera. Anti-overwhelm is a core game-design problem, not a styling problem.

### 3.1 Hierarchy: the one-number rule

Mobile dashboard practice converges on: **if the user sees only one number before pocketing the phone, which is it?** That number gets the largest type, visible without interaction; everything else is progressive disclosure ([Boundev mobile data viz guide](https://www.boundev.com/blog/mobile-data-visualization-design-guide), [Material data viz](https://m2.material.io/design/communication/data-visualization.html)).

**[SPEC] Per live ad slot, exactly three layers:**
1. **Hero number** — one metric the current goal cares about (e.g., ROAS during scaling, hook rate during testing). Big: ~40–56 pt, tabular figures, with a colored delta arrow.
2. **Strip** — 3 supporting micro-metrics max (hook %, CTR, spend) at ~15–17 pt, each with a 40–60 px sparkline. No axes, no labels on sparklines — trend only.
3. **Drill-in** — tap the slot → full-screen breakdown (funnel: impressions → thumbstops → clicks → conversions; frequency curve; fatigue meter). This is the "option to go deeper" and where the *teaching* happens.

Never show more than **3–4 KPIs** at rest. The genius of slot-machine/Balatro presentation is that the math happens *as animation* (chips × mult counting up), not as a table.

### 3.2 Motion is the legibility trick

- **Counting/odometer numbers:** animate value changes by rolling digits or count-up interpolation (ease-out, 300–800 ms; longer = bigger win). This is the single highest juice-per-effort technique for a metrics game — the number going up IS the dopamine ([Game UI Database — Scoring & Combos](https://www.gameuidatabase.com/index.php?scrn=136)). Pair each visible increment with the metric-tick haptic (rate-limited).
- **[SPEC] Tick cadence:** simulate continuously but *present* discretely — batch metric updates into visible ticks every 250–500 ms. A counter that updates 60×/s reads as noise; one that ticks 2–4×/s reads as a living thing.
- **Meters over numbers for state:** fatigue is a draining bar/dial, frequency is a filling gauge. Numbers for performance, meters for condition.
- **Sparklines** carry trend without space ([sparkline practice](https://sparkco.ai/blog/mastering-advanced-sparklines-a-comprehensive-guide)); cap at last N ticks (rolling window), draw at 2 px stroke minimum for legibility.

### 3.3 Color: colorblind-safe by default

~8% of men have some CVD. A game whose core skill is *reading data* cannot encode meaning in red-vs-green alone.

- **Categorical palette: Okabe-Ito** (the de facto standard, recommended by Nature journals, default in R ≥ 4.0): `#E69F00` orange, `#56B4E9` sky blue, `#009E73` bluish green, `#F0E442` yellow, `#0072B2` blue, `#D55E00` vermillion, `#CC79A7` reddish purple, `#000000` black ([The Node — data viz with flying colors](https://thenode.biologists.com/data-visualization-with-flying-colors/research/), [R Journal — Coloring in R's Blind Spot](https://journal.r-project.org/articles/RJ-2023-071/)). Confidence: **high**.
- **Continuous scales (heat, fatigue): viridis family** — perceptually uniform, CVD-safe.
- **[SPEC] Redundant encoding everywhere:** up/down = arrow glyph + position + color (never color alone); good/bad metrics also differ by icon shape; fatigue warning uses pattern (pulsing) + haptic, not just amber. Run final palettes through a CVD simulator (Sim Daltonism on macOS) as a release gate.
- Dark UI base: on OLED, dark backgrounds also save battery in a long-session game — and make the Okabe-Ito accents pop. (Bump yellow/sky-blue usage on dark; pure `#000` text color obviously inverts to off-white.)

---

## 4. Performance: 60/120 fps, ProMotion, Battery

A real-time sim renders continuously — unlike Balatro, you can't idle at 1% GPU between inputs. Power discipline is a design requirement.

- **ProMotion (iPhone 13 Pro+ / iPad Pro):** apps are capped at 60 Hz unless you add **`CADisableMinimumFrameDurationOnPhone` = true** to Info.plist, then request rates via `CADisplayLink.preferredFrameRateRange` (e.g. min 30 / preferred 60 / max 120). Apple made it opt-in explicitly for battery ([Apple docs](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange), [iMore on the 13 Pro clarification](https://www.imore.com/apple-clears-120hz-iphone-13-pro-confusion-developers)). Confidence: **high**. Note your Lua framework must expose this — stock LÖVE 11.5 doesn't; another item for the fork/extension list.
- **Android:** use `Surface.setFrameRate()` / Swappy (Android Game SDK) to negotiate refresh rate; same principle — match display rate to content rate, don't render 120 when nothing moves ([Android refresh-rate guide](https://developer.android.com/games/optimize/display-refresh-rate-change), [power guide](https://developer.android.com/games/optimize/power)).
- **Thermals are the silent killer of "real-time" games:** devices begin throttling at ~35–40 °C surface temp; mid-range phones can start stepping down within ~20–30 min of sustained load, flagships last longer. If your sim+render burns hot, the *feel* degrades exactly when the player is deepest in a session. Confidence: **medium** on the exact minute figures (vendor-dependent), **high** on the phenomenon.
- **[SPEC] Frame-rate policy:**
  - Simulation tick decoupled from render (sim at 10–20 Hz is plenty for ad metrics; interpolate visuals).
  - **120 Hz only during touch interactions** (card drag tracks finger — this is where ProMotion is *felt*) and shout-class payoff moments; settle to 60 during live-watch; drop to 30 on pure dashboard idle.
  - Battery saver toggle (force 30/60, reduce particles) + auto-degrade on thermal state callbacks (`ProcessInfo.thermalState` / Android `PowerManager.getThermalStatus`).
  - Target: a 30-minute session should not visibly throttle on a 3-year-old mid-range Android. Make this a perf test, not a hope.
- 2D card rendering is cheap; the risk is **particles + full-screen shaders on every payoff**. Budget: payoff VFX ≤ 4 ms GPU at 60 Hz on the floor device.

---

## 5. Feel-Spec Quick Reference (one screen for the team)

| Moment | Visual | Audio | Haptic class | Notes |
|---|---|---|---|---|
| Pickup | card lifts above thumb, 1.15× | soft paper slide | Whisper | 120 Hz while tracking |
| Hover slot | slot glow, card lean | — | Whisper (detent) | once per slot entry |
| Snap | ≤120 ms seat + overshoot | click | Voice | sync all three to same frame |
| Launch | windup 200 ms → burst | riser + thump | Voice→Shout | AHAP w/ embedded audio on iOS |
| Metric tick | digit roll, 2–4 ticks/s | soft tick (optional) | Whisper, rate-limited | batch sim updates |
| Jackpot | count-up 800 ms+, particles | slot payoff swell | Shout (≤1/10 s) | the Balatro moment |
| Fatigue | meter pulse, amber pattern | low woodblock ×2 | Voice (dull) | never color-only |
| Fail | sag/desaturate | dead thud | Voice (heavy, soft sharpness) | brief; don't punish twice |

---

## 6. Open Questions for Other Tracks

1. **Framework choice** must weigh the haptics finding: Solar2D = haptics free today; Defold = clean extension path; LÖVE = engine fork (precedented by Balatro, but owned by us). Whoever owns the engine track should treat "can we ship the haptic vocabulary + ProMotion control" as a hard requirement.
2. Portrait-first constrains the slot count visible at once (likely 2–3 live ads without scrolling) — economy design should know this early.
3. The drill-in dashboard is the education surface — content/learning track should own its information design using §3's layer model.

---

## Sources

**Card UX / reference games**
- https://www.smashingmagazine.com/2016/09/the-thumb-zone-designing-for-mobile-users/
- https://alistapart.com/article/how-we-hold-our-gadgets/
- https://blog.logrocket.com/ux-design/all-accessible-touch-target-sizes/
- https://github.com/jfmmm/BalatroMobileLikeDragging
- https://balatrowiki.org/w/Updates
- https://www.androidcentral.com/slay-spire-android-game-week
- https://curaxuan.com/game-ux-marvel-snap-ux-redesign/
- https://medium.com/@carol.michelon/marvel-snap-gameplay-wireframe-ed76251eebc5
- https://www.pencilandpaper.io/articles/ux-pattern-drag-and-drop

**System gestures**
- https://developer.apple.com/documentation/uikit/uiviewcontroller/2887512-preferredscreenedgesdeferringsys
- https://useyourloaf.com/blog/avoiding-conflicts-with-system-gestures-at-screen-edges/
- https://developer.android.com/develop/ui/views/touch-and-input/gestures/gesturenav

**Haptics — iOS**
- https://developer.apple.com/documentation/corehaptics
- https://developer.apple.com/videos/play/wwdc2019/520/
- https://developer.apple.com/videos/play/wwdc2019/810/
- https://developer.apple.com/videos/play/wwdc2021/10278/
- https://developer.apple.com/design/human-interface-guidelines/playing-haptics
- https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/feedbackstyle/soft
- https://sarunw.com/posts/play-haptic-feedback-using-uifeedbackgenerator/
- https://medium.com/lofelt/10-things-you-should-know-about-designing-for-apple-core-haptics-9219fdebdcaa

**Haptics — Android**
- https://developer.android.com/develop/ui/views/haptics/custom-haptic-effects
- https://developer.android.com/develop/ui/views/haptics/haptics-apis
- https://developer.android.com/develop/ui/views/haptics/haptics-principles
- https://source.android.com/docs/core/interaction/haptics/haptics-ux-design
- https://thomas--mcguire.medium.com/exploring-new-haptics-features-in-android-12-27844dba9635

**Haptics — Lua framework access**
- https://love2d.org/wiki/love.system.vibrate
- https://github.com/love2d/love/issues/1904
- https://github.com/love2d/love/pull/2247
- https://github.com/love2d/love/releases
- https://docs.coronalabs.com/api/library/system/vibrate.html
- https://github.com/coronalabs/corona/releases/tag/3718
- https://defold.com/assets/vibration/
- https://github.com/adamwestman/extension-vibrate
- https://forum.defold.com/t/tapticengine-native-extension-for-ios-taptic-engine/57279
- https://github.com/MaratGilyazov/def_taptic_engine

**Audio-haptic sync**
- https://arxiv.org/pdf/2307.05451
- https://source.android.com/docs/core/audio/latency/latency

**Marvel Snap haptics in practice**
- https://www.xda-developers.com/marvel-snap-mobile-game-haptics/
- https://gameranx.com/features/id/401290/article/marvel-snap-how-to-turn-off-vibrate/

**Data viz on mobile**
- https://www.boundev.com/blog/mobile-data-visualization-design-guide
- https://m2.material.io/design/communication/data-visualization.html
- https://thenode.biologists.com/data-visualization-with-flying-colors/research/
- https://journal.r-project.org/articles/RJ-2023-071/
- https://sparkco.ai/blog/mastering-advanced-sparklines-a-comprehensive-guide
- https://www.gameuidatabase.com/index.php?scrn=136

**Performance / ProMotion / battery**
- https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange
- https://www.imore.com/apple-clears-120hz-iphone-13-pro-confusion-developers
- https://developer.android.com/games/optimize/display-refresh-rate-change
- https://developer.android.com/games/optimize/power
