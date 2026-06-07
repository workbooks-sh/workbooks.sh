# Local-First Architecture Research — Addendum

**Track:** localfirst · **Date:** 2026-06-05 · **Status:** research complete
**Scope:** Content-as-data, asset bundling, save system, determinism, sim tick architecture, and future escape hatches for a no-server, mobile-first, Balatro-style real-time ad-account simulator.

---

## 0. Executive summary

A no-server, content-driven card/sim game is an extremely well-trodden architecture — Balatro itself ships this way (LÖVE + Lua data files + local saves, ~70–141 MB on mobile). Every requirement in this track is achievable with boring, proven techniques. The two load-bearing decisions are:

1. **Treat content as declarative Lua tables** (pure data, zero logic), validated by a dev-time schema checker and stamped with an integer `content_format` version. This wins on moddability, hot-reload, and zero-parser friction in a Lua engine, and it is exactly what Balatro and Factorio do.
2. **Make the simulation a deterministic, integer-seeded, fixed-timestep state machine** that owns its own serializable PRNG(s) and never touches wall-clock time, `pairs()` ordering, or libm transcendentals. Determinism is nearly free if designed in on day one and nearly impossible to retrofit.

Engine-relevant facts that materially affect this track: **LÖVE's latest stable is still 11.5 (Dec 2023); 12.0 remains nightly-only as of mid-2026.** LÖVE mobile packaging is DIY (Xcode/Gradle projects), there is no built-in hot-reload-to-device, no live-update story, and `love.filesystem` lacks an atomic rename. **Defold (1.12.4, May 2026) ships every escape hatch we want built-in**: ~2 MB base bundles, native `fixed_update` at a configurable Hz, atomic `sys.save` (temp-file + rename, verified in engine source), editor hot-reload to a phone over Wi-Fi, and a first-class Live Update system for post-launch content packs. The one Defold trap: on iOS it runs vanilla Lua 5.1 (not LuaJIT), whose `math.random` is platform-dependent C `rand()` — so **on either engine, the sim must own its own deterministic PRNG and never use global `math.random`.**

---

## 1. Content-as-data: Lua tables vs JSON vs SQLite

### 1.1 The three options

| | Lua tables (data-only modules) | JSON | SQLite |
|---|---|---|---|
| Parse cost | Zero (it *is* the host language); LuaJIT loads MB-scale data files instantly | Needs a lib (rxi/json.lua, dkjson, lua-cjson); Defold has built-in `json.decode`/`json.encode` | Needs native lib (`lsqlite3`) — must be cross-compiled for iOS/Android in LÖVE; community extensions in Defold |
| Expressiveness | Comments, trailing commas, multi-line strings, light templating (`for` loops to stamp variants), constants/refs | None of that; no comments is genuinely painful for hand-edited game content | SQL — total overkill for a few thousand static records |
| Moddability | Highest — modders already write Lua; Balatro's entire mod scene (Steamodded) works by injecting Lua data | Fine, but mods that are "just data" are less interesting than Balatro-style data+hooks | Worst — binary file, needs tooling |
| Validation | Needs discipline: a schema checker you write (~200 LOC) + `luacheck` in CI; Teal (typed Lua) optional | JSON Schema exists (`ljsonschema` in Lua, or validate in CI with any language) | Schema enforced by DB, but migrations of *content* via SQL are miserable |
| Hot-reload | Trivial — re-`dofile` the module (rxi/lurker in LÖVE; Defold hot-reloads any resource to device) | Trivial too | Awkward |
| Risk | A data file can execute arbitrary code — fine for shipped content, a consideration for community mods | Inert/safe | Inert/safe |
| Diffability/git | Good (one record per block, stable key order if you keep arrays) | Good | Bad (binary) |

**Recommendation: Lua tables, with rules.** Real precedents: Factorio's entire prototype/data stage is Lua tables; Balatro's jokers/cards are Lua; Defold and LÖVE both make `require`-ing a data module a one-liner. JSON adds a parser and removes comments for no benefit when both candidate engines are Lua-native. SQLite buys nothing at the scale of a card game (hundreds–low-thousands of records, all loaded into RAM at boot) and costs a native dependency.

Use JSON only as an **interchange/export format** if you later build external balancing tools (spreadsheet → JSON → checked into repo → converted to Lua, or loaded directly via `json.decode`).

### 1.2 The discipline (this is the part that matters)

1. **Data-only modules.** Every content file is `return { ... }` — plain tables, no function values, no upvalues, no `require` of game code. Enforce mechanically: load content files in a sandboxed env (`setfenv` in Lua 5.1) with an empty/whitelisted global table; the loader rejects any file that calls anything outside the whitelist. This keeps "content" portable to JSON later if ever needed, and keeps mod review tractable.
2. **One file per domain, one registry.** `content/cards/hooks.lua`, `content/cards/formats.lua`, `content/audiences.lua`, `content/tuning.lua`. A single `content/init.lua` loader merges them into registries keyed by id.
3. **Stable string IDs, never reused.** `id = "hook_ugc_testimonial_v1"`. IDs are forever — saves, analytics, and mods reference them. Renaming = add new id + alias table, never edit in place.
4. **`content_format` integer at pack level.** Bump on breaking shape changes. Loader refuses packs with a higher major than it understands (matters once live-update packs exist). Each record may carry `since = <content_format>` for tooling.
5. **Schema checker runs on boot in dev and in CI.** Hand-roll it: a declarative schema table (`field -> {type=, required=, enum=, range=}`) and a walker. ~200 lines, no dependency, gives errors like `cards/hooks.lua: hook_pet_open[12].fatigue_rate: expected number in [0,1], got "fast"`. Add `luacheck` for syntax/typo-level errors. (If you want typed authoring, Teal compiles to Lua 5.1 and types record shapes — optional, evaluate later.)
6. **Golden-test the sim against content in CI.** Fixed seed + fixed content → run N ticks headless → hash the metrics trace → compare to checked-in hash. Catches both accidental content edits and sim nondeterminism in one test (see §4).
7. **Hot-reload in dev.** LÖVE: rxi/lurker (https://github.com/rxi/lurker) watches files and hot-swaps modules; wire a `content.reload()` that re-runs loader + validator and rebuilds registries. Defold: built-in — File ▸ Hot Reload pushes a changed resource to a *running game on the device* (https://defold.com/manuals/hot-reload/). Either way, design registries to be rebuildable mid-session: live run state references content by id, never by direct table reference held across reloads.

### 1.3 Tuning data specifically

Audience resonance patterns and sim tuning are also content. Two extra rules:

- **Patterns are data, not code**: express resonance as declarative weight tables (`{ audience = "a_homeowners", axis = "thumbstop", tags = {"ugc","pet"}, weight = 0.8 }`), and let the sim interpret them. This keeps daily-seed pattern shuffling (§4) and difficulty variants possible without code changes — and live-updatable later.
- **Keep secret patterns out of player-readable plain text if you care.** Lua data in a zip is trivially readable; that's fine (Balatro is fully datamined and thriving), but accept it consciously. Obfuscation is not worth it.

---

## 2. Asset bundling and app-size budgets

### 2.1 LÖVE packaging (current reality, verified June 2026)

- **Latest stable is 11.5 (Dec 3, 2023).** 12.0 has been "close" for over a year (1,100+ commits, nightlies on GitHub Actions, some commercial games shipped on nightlies; min iOS raised to 13.0) but is **not released** as of June 2026 — love2d.org still serves 11.5. (https://github.com/love2d/love/releases, https://love2d.org/forums/viewtopic.php?t=96418)
- A game is a `.love` file — literally a zip of the project. Desktop "fusing" appends it to the executable.
- **Android:** clone `love2d/love-android`, drop your game into `app/src/embed/assets/`, set package id/version in Gradle, `./gradlew bundleEmbedNoRecordRelease` → AAB. You own the Android project (SDK/NDK version pinning included). (https://love2d.org/wiki/Game_Distribution)
- **iOS:** open `platform/xcode/love.xcodeproj`, add `game.love` to the love-ios target's Copy Bundle Resources, build. You own the Xcode project. (https://love2d.org/wiki/Getting_Started#iOS)
- Assets live inside the zip; `love.filesystem` reads them transparently. Notably, **`love.filesystem.mount` can mount additional zips from the save directory** — that is the LÖVE DIY equivalent of a content-pack system (§6).
- **JIT is off on mobile**: forbidden by iOS, and LÖVE deliberately disables the JIT on *all* arm64 (including Android) due to LuaJIT code-memory range issues — you get the LuaJIT interpreter, which is still much faster than PUC Lua. Balatro ships fine this way. (https://love2d.org/forums/viewtopic.php?t=81711, https://love2d.org/forums/viewtopic.php?t=95733)

Community tooling (makelove, love-actions GitHub Actions, love-build) automates desktop well; mobile remains "maintain your own Xcode/Gradle wrapper." Budget real engineering time for this if choosing LÖVE.

### 2.2 Defold packaging (verified June 2026)

- **Latest release 1.12.4 (May 4, 2026)** — monthly cadence, source-available under the Apache-2.0-derived Defold License, free, no royalties. (https://defold.com/2026/05/04/Defold-1-12-4/, https://defold.com/faq/faq/)
- One-click bundling to signed iOS IPA / Android AAB from the editor or headless via `bob.jar` (CI-friendly). Assets compile into engine archive files inside the bundle.
- **Base engine bundles are famously small — ~2 MB** before your assets. (https://defold.com/)
- **Texture profiles** per-platform: Basis Universal (ETC1S = very small, UASTC = high quality) transcoded at runtime to the device's native format (ASTC/ETC2/BCx) — this is the serious answer to card-art size at scale. (https://defold.com/manuals/texture-profiles/)
- **Live Update** is first-class: mark collection proxies "Exclude," publish excluded resources as zip archives (any static host, or S3 directly), download and `liveupdate.add_mount()` at runtime with priorities. 1.12.4 added "Strip Live Update Entries from Main Manifest" (default on) shrinking base builds further. Android can even deliver live-update content through Play Asset Delivery. (https://defold.com/manuals/live-update/)
- Lua runtime: LuaJIT on most platforms, **vanilla Lua 5.1 on iOS and HTML5** (determinism consequence in §4). (https://defold.com/manuals/lua/)

### 2.3 Store size limits (verified June 2026) and our budget

| Constraint | Value |
|---|---|
| iOS max app size (uncompressed total) | 4 GB (https://www.simplymac.com/ios/ios-app-size-limits) |
| iOS cellular download | Default prompt threshold 200 MB; users can set "Always Allow" (iOS 13+) (https://www.idownloadblog.com/2019/10/25/about-app-store-cellular-download-limit/) |
| Google Play base AAB module | **200 MB hard limit** (https://support.google.com/googleplay/android-developer/answer/9859372) |
| Play install-time asset packs | 1 GB combined (per official support page; some 2025 docs cite higher per-pack limits — recheck at ship time) |
| Play fast-follow / on-demand packs | 512 MB each, up to 4 GB total app |

**Budget recommendation: ≤150 MB download, ideally ≤100 MB.** Rationale: stays under both stores' 200 MB friction lines with headroom for updates growth; Balatro mobile is ~70–93 MB download / ~141 MB installed and is the genre's gold standard for "feels premium, downloads instantly" (https://www.appbrain.com/app/balatro/com.playstack.balatro.android, https://www.sportskeeda.com/mobile-games/balatro-released-mobile-price-size-download-process-explained).

**Card-art math.** The single biggest size lever is **compositional card art**: because cards in this game are *components of an ad* (hook, format, angle, offer, audience), render each card as frame + shared iconography + per-card illustration, packed in atlases — not unique full-bleed paintings. Rough numbers at 512×716 per unique illustration:

- PNG in zip (LÖVE path): ~100–300 KB each → 300 cards ≈ 30–90 MB. Fine.
- Basis ETC1S (Defold path): ~0.5–1 bit/texel → 300 cards ≈ 15–35 MB. Better, plus lower runtime RAM.
- 1,000+ cards stays under budget on either path if illustrations share parts; it blows up only with unique 4K art per card — don't do that.

Audio is the usual silent killer: ship music as mono/joint-stereo OGG ~96–128 kbps, SFX short OGG; budget ~15–25 MB.

---

## 3. Save system

### 3.1 Three save domains, three files, three cadences

| Domain | Contents | Written when | File |
|---|---|---|---|
| **Settings** | audio/haptics/accessibility/locale | on change | `settings.dat` |
| **Meta-progression** | card collection, unlocks, client/business progress, stats, achievements-pending | at run boundaries + on key unlocks | `profile.dat` |
| **Run state** | current run: deck, live campaigns, market/audience state, economy, **sim tick index, PRNG states** | checkpoint every N sim-seconds and at app lifecycle events | `run.dat` |

Separation matters because corruption blast radius differs: losing `run.dat` costs one run; losing `profile.dat` costs the player's life. Never co-mingle. Keep an automatic `profile.dat.bak` rotated on every successful write.

**Run-state strategy for a real-time sim:** snapshot, don't journal. Serialize the full sim state (it's small — KBs) at a checkpoint cadence of ~5–10 s of sim time *and* on every `pause`/`background`/`quit` lifecycle event. Because the sim is deterministic (§4), an alternative is snapshot + input-journal replay, which is also your debugging replay tool — recommended as a dev facility, optional for production saves.

### 3.2 Atomic writes on mobile (the part everyone gets wrong)

The only safe pattern on iOS/Android: **write to a temp file in the same directory → flush/close → rename over the destination.** POSIX `rename()` is atomic on APFS and ext4/f2fs; a crash mid-write leaves the old save intact.

- **Defold: `sys.save()` already does this.** Verified in engine source (`engine/script/src/script_sys.cpp`): it writes to `"%s.defoldtmp_%x_%d"` then `dmSys::Rename` onto the target (all platforms except HTML5). Caveats: 512 KB max output size and 65,536 max table rows — fine for our state, but don't dump giant histories into one table. Also, since 1.10.3 `sys.load()` raises a Lua error on corrupt files instead of crashing — wrap in `pcall` and fall back to `.bak`. (https://forum.defold.com/t/defold-1-10-3-beta/80778, https://defold.com/ref/stable/sys-lua/)
- **LÖVE: `love.filesystem` has no rename — roll the pattern yourself.** `love.filesystem.write("run.dat.tmp", blob)` then `os.rename(saveDir.."/run.dat.tmp", saveDir.."/run.dat")` using `love.filesystem.getSaveDirectory()` for absolute paths. This is the long-standing community workaround (https://love2d.org/forums/viewtopic.php?t=3594). Wrap it once in a `savefile.lua` util and never call raw writes elsewhere. Note `love.filesystem.write` does not fsync; accept that or use `io.open`+`flush` on the absolute path.
- **Checksum every save.** Prefix the payload with a version int + CRC32/FNV hash of the body. On load: verify hash → if bad, try `.bak`. Both engines can hash cheaply (LÖVE: `love.data.hash`; Defold: pure-Lua FNV or `crypto` extensions).
- **Write on lifecycle events.** iOS gives no exit guarantee — apps get suspended then killed silently. LÖVE: save in `love.focus(false)` and `love.quit`. Defold: listen for `window.set_listener` `WINDOW_EVENT_FOCUS_LOST` / iconify. Never rely on "save on quit" alone.

### 3.3 Save-schema migrations

- Every save file starts with `save_version = <int>` (independent of `content_format`).
- Migrations are an ordered table: `migrations[3] = function(save) ... returns save as v4 ... end`. On load, apply sequentially from file version to current. Pure functions, no game-state access.
- **Keep fixture saves in the repo** — one per historical version — and a CI test that loads + migrates each to current and validates against the schema checker. This is the only thing that makes update-day safe.
- Content references in saves are **string ids** (§1.2); when content is removed, the loader maps unknown ids through an `aliases`/`retired` table (refund/replace policy is a design decision — make it explicit, players notice).
- Never migrate in place without first copying to `profile.dat.pre-v<N>` — one file, kept until next successful migration.

---

## 4. Determinism: seeded RNG and replayable runs

### 4.1 Why now

Deterministic sim = replayable bug reports (seed + inputs instead of "it felt wrong"), golden tests in CI, ghost/share features, and **daily-seed challenges later for free**. Retrofitting determinism into a sim that mixes UI randomness, wall-clock time, and table-order iteration is a rewrite. The rules below cost ~zero if adopted on day one.

### 4.2 PRNG architecture

1. **The sim owns its RNG objects. Global `math.random` is banned from sim code** (lint for it). UI juice (particle jitter, card wobble) uses a *separate* non-sim RNG so cosmetic effects never consume sim entropy.
2. **Run seed → named substreams.** Derive one PRNG per subsystem from the 64-bit run seed: `market = prng(hash(seed, "market"))`, `audience = prng(hash(seed, "audience"))`, `events = prng(hash(seed, "events"))`. Substreams stop "one extra UI roll shifted every subsequent outcome" bugs and let systems evolve independently. (This is the Factorio model — its `LuaRandomGenerator` is exactly a save/loadable, re-seedable generator decoupled from everything else: https://lua-api.factorio.com/latest/classes/LuaRandomGenerator.html)
3. **PRNG state is part of run save state.** Serialize every substream's state in `run.dat`; restoring a save must continue the exact sequence.
4. Engine specifics:
   - **LÖVE:** `love.math.newRandomGenerator(seed)` is ideal — engine-implemented **xorshift64\*** (verified in source: Marsaglia xorshift with Thomas Wang seed-hash), integer-based so identical on every platform, with `getState()`/`setState()` returning a hex string for serialization. (https://github.com/love2d/love/blob/main/src/modules/math/RandomGenerator.cpp)
   - **LuaJIT platforms:** `math.random` is a Tausworthe PRNG, period 2^223, documented to generate "the same sequences from the same seeds on all platforms" (https://luajit.org/extensions.html) — deterministic, but it's *one global stream*, so still wrap your own objects.
   - **Defold on iOS/HTML5 runs vanilla Lua 5.1**, whose `math.random` is platform C `rand()` — **not portable**. On Defold, ship your own PRNG in pure Lua: PCG32 or xorshift128 implemented on 32-bit integers via the `bit` library (32-bit values are exactly representable in doubles; LuaJIT bitop semantics are consistent across platforms). ~40 lines, write golden tests for the first 1,000 outputs and run them on every target.
5. **Daily seeds offline:** seed = hash(UTC date string + salt). With no server, clock-cheating is possible — accept it (no leaderboards yet) and design daily rewards to not matter competitively. The deterministic sim is what makes server-verified dailies *possible later*: a server can replay the run from seed + input log.

### 4.3 Float nondeterminism in Lua — actual risk profile

Lua numbers are IEEE 754 doubles. The honest picture:

- **Basic arithmetic (`+ - * /`, comparisons) on doubles is bit-identical across modern targets** (arm64 phones, SSE2-era x86-64 desktops) — IEEE 754 is strict for these. The classic x87-80-bit horror stories don't apply to our targets.
- **Real dangers, in order:**
  1. **`math.sin/cos/exp/pow/log` route to the platform libm and DO differ across OSes** in last-bit results. Ban transcendentals in the sim; if a curve needs them, precompute lookup tables in content or use polynomial approximations you ship. (Background: https://gafferongames.com/post/floating_point_determinism/, https://shaderfun.com/2020/10/25/understanding-determinism-part-1-intro-and-floating-points/)
  2. **`pairs()` iteration order is unspecified** (Lua 5.1 manual: `next` order undefined) and varies with table history/hash seeding. Any sim loop over entities must iterate arrays or sorted key lists. This bites more real Lua games than floats do.
  3. **JIT vs interpreter divergence** (LuaJIT may fuse ops differently when compiled): mostly moot for us because mobile arm64 runs interpreter-only anyway (§2.1), but if desktop builds enable JIT, your CI golden test across desktop+device catches it; worst case `jit.off()` on the sim module.
  4. **Locale/string round-trips:** never serialize sim numbers via `tostring`/`string.format("%f")` — save raw doubles (Defold `sys.save` keeps Lua numbers losslessly; in LÖVE use `string.pack("<d", x)` in 12.0 / love.data, or keep sim values integer).
- **Strongest mitigation, recommended anyway for a *market* sim: keep sim state integer.** Money in cents, rates in basis points, impressions as counts, weights as 0–10,000 integers. Doubles represent integers exactly up to 2^53, so plain Lua arithmetic on integer-valued doubles is perfectly deterministic with zero fixed-point library needed — just discipline: divide only at presentation time. This also makes metrics display cleanly ("CTR 1.24%") without float dust.
- Define a `simhash(state)` debug function (order-stable fold over the state tree) and assert it in CI golden runs and optionally at checkpoint saves.

---

## 5. Sim architecture: fixed-timestep tick, decoupled from render

### 5.1 Core loop

Canonical pattern: **fixed-timestep accumulator** (Gaffer on Games, "Fix Your Timestep!", https://gafferongames.com/post/fix_your_timestep/):

```
accumulator += frame_dt (clamped to a max, e.g. 0.25s)
while accumulator >= TICK_DT:
    sim.tick(world)        # deterministic, integer tick index
    accumulator -= TICK_DT
render(interpolate or latest snapshot)
```

- **Sim time is the tick counter, never wall clock.** `world.tick` is a monotonically increasing integer; everything (fatigue curves, campaign durations, spend pacing) is defined in ticks. Saves store the tick index.
- **Recommended tick rate: 8–10 Hz for the market sim.** This is a numbers sim, not physics: impressions, auctions, spend pacing and fatigue all read perfectly when updated 8–10×/sec, and metric *display* can interpolate between ticks for that live-dashboard shimmer. Cheap on battery (the expensive thing on mobile is rendering, but a 10 Hz sim leaves headroom on low-end Android), and the time-compression knob is then trivial: 1 sim-tick = e.g. 10 "sim-world minutes," and fast-forward = run N ticks per frame (deterministic by construction — same ticks, just faster wall-clock). Defold makes this native: `fixed_update(self, dt)` runs 0..N times per frame at `engine.fixed_update_frequency` Hz set in game.project (https://defold.com/manuals/application-lifecycle/); in LÖVE you write the 10-line accumulator in `love.update`.
- **UI/juice runs at render rate** (60 Hz+) and reads sim snapshots; it must never mutate sim state directly — it emits *commands* (play ad, pause campaign, reallocate budget) that the sim consumes at tick boundaries. This command queue is exactly the input journal for replays (§4).

### 5.2 Backgrounding: recommend a deliberate no-offline-progress stance (v1)

When the app backgrounds (and is then frozen/killed by the OS — guaranteed on iOS), three options:

1. **Pause the sim entirely (recommended).** The whole fantasy is *watching* ads perform live and reacting; progress accrued while not watching undermines the attention loop, the tension, and the teaching goal (you learn by reading the dashboard, not by collecting offline yield). Balatro has zero offline progress and nobody asks for it. Implementation: save on `focus lost`, on resume just continue from the saved tick. Zero catch-up code, zero determinism risk, zero "I came back to a dead account" rage. Also sidesteps clock-tampering exploits.
2. Bounded catch-up: on resume, run `min(elapsed_wallclock / TICK_DT, CAP)` ticks (cap ≈ 30–120 sim-seconds) behind a "While you were away…" recap. Deterministic and cheap *if* wanted later — the fixed-tick design makes it a pure policy choice, no architecture change. Note wall-clock elapsed must then enter the sim, which weakens replay purity — log it as an input event ("resume after K ticks") so replays still work.
3. Full idle-game offline progress: explicitly out — it changes the genre.

Ship (1); keep (2) as a design-policy escape hatch. Either way the decision lives in one place: the resume handler.

---

## 6. Future escape hatches (kept cheap now)

### 6.1 Content updates without app-store releases

**App Store legal line first:** Apple guideline 2.5.2 — apps may not "download, install, or execute code which introduces or changes features or functionality." **Data-only packs (card definitions, balance tables, art, audio) are fine; downloading new *Lua code* is not** (a bundled interpreter may only run scripts shipped in the bundle). Design the boundary accordingly: new card *content* must be expressible in the declarative data schema (§1.3) interpreted by shipped code. (https://saagarjha.com/blog/2020/11/08/fixing-section-2-5-2/, https://developer.apple.com/forums/thread/52161)

- **Defold: built-in.** Live Update publishes excluded collections as zip archives to any static host (or S3 with auto-upload); at runtime download, verify, `liveupdate.add_mount(name, uri, priority)` and the resource system reads from the highest-priority mount. Higher-priority mounts can also *override* base-bundle files — i.e., balance hotfixes without a release. Works offline-first: mounts persist locally. (https://defold.com/manuals/live-update/, https://defold.com/manuals/live-update-scripting/)
- **LÖVE: DIY but genuinely simple** because §1 made content pure data: download a zip of Lua-table content (over HTTPS via luasocket/lua-https or a small native helper) into the save directory, verify a hash, then `love.filesystem.mount("packs/summer_meta.zip", "content_packs/summer")` and run it through the same sandboxed loader + validator + `content_format` gate. The validator-on-load is now a *security* layer too — the sandbox from §1.2 is what makes remote data safe.
- Either way: packs carry `content_format`, a manifest with hashes, and a min-app-version; the loader refuses incompatible packs gracefully.

**Cost today: ~zero.** Everything required (data-only content, sandboxed loader, versioned packs, id-stable saves) is already mandated by §§1, 3.

### 6.2 Optional cloud sync later

- Keep **all durable player state in one serializable document** (`profile.dat` + completed-run summaries) with a monotonically increasing `revision` counter and a device id. That alone makes later sync trivial: last-write-wins on `revision` covers a solo game; per-field merge (collection = set-union, currencies = max or CRDT-ish counters) is an upgrade path. Don't build any of it now — just don't scatter player state across many ad-hoc files.
- Cheapest first step when wanted, no backend: **iCloud Key-Value / iCloud Documents on iOS** (entitlement + file copy of `profile.dat`) and **Android Auto Backup** (free, `profile.dat` < 25 MB, zero code) — note Auto Backup is best-effort, not sync.
- Telemetry: none by default. If ever added, opt-in only, and the deterministic design means the *useful* diagnostic artifact is tiny anyway: seed + input journal + sim hash, attached to a user-initiated bug report. That's both more respectful and more debuggable than analytics events.

---

## 7. Consolidated recommendations

1. **Content = sandboxed, data-only Lua table modules** with stable string ids, a hand-rolled schema validator (boot in dev + CI), `luacheck`, and an integer `content_format`. JSON only as tool interchange; no SQLite.
2. **Budget ≤150 MB download** (Balatro: ~70–93 MB). Compositional card art in atlases, compressed textures (Basis ETC1S on Defold), OGG audio. Hard ceilings: 200 MB Play base AAB, 200 MB iOS cellular prompt.
3. **Three save files** (settings / profile / run) + `.bak` rotation; **atomic temp+rename writes** (free via Defold `sys.save`; wrap `os.rename` in LÖVE); version int + checksum header; ordered migration functions with fixture saves replayed in CI; save on focus-loss, never only on quit.
4. **Determinism day one:** sim-owned serializable PRNGs (xorshift/PCG, substream per system, state in saves), global `math.random` banned in sim, no libm transcendentals (LUTs instead), no `pairs()` in sim loops, integer-valued sim state (cents/bps/counts), seed+command journal = replay, golden-hash test in CI across desktop+device. On Defold specifically, ship a pure-Lua PRNG (iOS is vanilla Lua 5.1).
5. **Fixed-timestep sim at ~10 Hz** (tick counter is canonical time), commands queued at tick boundaries, render interpolates at 60 Hz. **No offline progress in v1** — pause on background, save on focus-loss; bounded catch-up remains a policy switch, not an architecture change.
6. **Escape hatches:** data-only content packs (Defold Live Update built-in; LÖVE via `love.filesystem.mount` of downloaded zips) — never downloadable code (Apple 2.5.2); single versioned profile document so cloud sync later is a feature, not a refactor.
7. **Engine signal from this track** (final call belongs to the engine track): Defold currently wins the local-first checklist on facts — released cadence (1.12.4, May 2026) vs LÖVE 12 still unreleased, ~2 MB bundles, native `fixed_update`, atomic saves, hot-reload-to-device, built-in live-update, one-click mobile bundling. LÖVE's counterweights: Balatro pedigree, simpler mental model, `love.math.newRandomGenerator` determinism out of the box, and total code-level freedom. Both are viable; nothing in this report blocks either.

---

## 8. Sources

- LÖVE releases (11.5 latest): https://github.com/love2d/love/releases
- LÖVE 12.0 timeline thread: https://love2d.org/forums/viewtopic.php?t=96418
- LÖVE homepage (still 11.5): https://love2d.org/
- LÖVE Game Distribution (fusing, Android/iOS packaging, mount tooling): https://love2d.org/wiki/Game_Distribution
- LÖVE RandomGenerator source (xorshift64\*, getState/setState): https://github.com/love2d/love/blob/main/src/modules/math/RandomGenerator.cpp
- love.math.newRandomGenerator: https://love2d.org/wiki/love.math.newRandomGenerator
- LÖVE iOS/LuaJIT interpreter-only: https://love2d.org/forums/viewtopic.php?t=81711 and arm64 JIT-off discussion: https://love2d.org/forums/viewtopic.php?t=95733
- love.filesystem rename workaround: https://love2d.org/forums/viewtopic.php?t=3594
- rxi/lurker hot reload: https://github.com/rxi/lurker
- LuaJIT extensions (Tausworthe PRNG, cross-platform sequences): https://luajit.org/extensions.html
- Defold 1.12.4 release notes: https://defold.com/2026/05/04/Defold-1-12-4/
- Defold Live Update manual: https://defold.com/manuals/live-update/ and scripting: https://defold.com/manuals/live-update-scripting/
- Defold legacy LiveUpdate API deprecation: https://github.com/defold/defold/pull/12153
- Defold Lua manual (Lua 5.1 on iOS/HTML5, LuaJIT elsewhere): https://defold.com/manuals/lua/
- Defold sys.save/sys.load reference: https://defold.com/ref/stable/sys-lua/ and file access manual: https://defold.com/manuals/file-access/
- Defold sys.save atomic temp+rename (engine source): https://github.com/defold/defold/blob/dev/engine/script/src/script_sys.cpp
- Defold 1.10.3 corrupt-save load behavior change: https://forum.defold.com/t/defold-1-10-3-beta/80778
- Defold application lifecycle (fixed_update): https://defold.com/manuals/application-lifecycle/
- Defold fixed timestep beta discussion: https://forum.defold.com/t/game-physics-time-steps-beta-testing/70539
- Defold hot reload manual: https://defold.com/manuals/hot-reload/
- Defold texture profiles (Basis Universal/ASTC): https://defold.com/manuals/texture-profiles/
- Defold FAQ (license, size): https://defold.com/faq/faq/ and https://defold.com/
- Google Play size limits: https://support.google.com/googleplay/android-developer/answer/9859372
- Play asset-pack limit changes (2025 coverage): https://en.androidayuda.com/google-breaks-the-50-mb-barrier-for-android-apps/
- iOS app size limits: https://www.simplymac.com/ios/ios-app-size-limits and cellular threshold: https://www.idownloadblog.com/2019/10/25/about-app-store-cellular-download-limit/
- Balatro mobile size: https://www.appbrain.com/app/balatro/com.playstack.balatro.android, https://www.sportskeeda.com/mobile-games/balatro-released-mobile-price-size-download-process-explained
- Apple guideline 2.5.2 analysis: https://saagarjha.com/blog/2020/11/08/fixing-section-2-5-2/ and https://developer.apple.com/forums/thread/52161
- Factorio LuaRandomGenerator (deterministic RNG precedent): https://lua-api.factorio.com/latest/classes/LuaRandomGenerator.html
- Fix Your Timestep! (Gaffer on Games): https://gafferongames.com/post/fix_your_timestep/
- Floating Point Determinism (Gaffer on Games): https://gafferongames.com/post/floating_point_determinism/
- Understanding Determinism (shaderfun): https://shaderfun.com/2020/10/25/understanding-determinism-part-1-intro-and-floating-points/
- Deterministic-game gotchas (2025): https://www.jfgeyelin.com/2025/05/unexpected-gotchas-in-making-game.html
