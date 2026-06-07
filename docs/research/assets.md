# Assets Track — Art Direction & Asset Sourcing Research

**Project:** Addendum (working title) — real-time ad-account manager game, Balatro-vein aesthetic
**Date:** 2026-06-05 · **Track:** assets · **Status:** research complete, decisions proposed

---

## 1. What Balatro actually uses (documented facts)

### 1.1 Font: m6x11 / m6x11plus by Daniel Linssen (managore)

- Balatro's main font is **m6x11plus**, a 6×11 px pixel font by Daniel Linssen, confirmed by LocalThunk directly ("m6x11plus is the main font for Balatro" — [x.com/LocalThunk/status/1739882509826248882](https://x.com/LocalThunk/status/1739882509826248882)).
- **License: free to use with attribution.** Verified on the itch page ([managore.itch.io/m6x11](https://managore.itch.io/m6x11)), which ships both `m6x11.ttf` (12 kB) and `m6x11plus.ttf` (17 kB). Recommended render sizes: multiples of 16 for m6x11, multiples of 18 for m6x11plus (it's an 11px / 12px grid — integer multiples keep it crisp).
- [Fonts In Use confirms](https://fontsinuse.com/uses/65816/balatro-computer-game) the font is used "throughout, often with an animated bouncing effect" — the type IS the animation system. Balatro renders each glyph as a quad it can bounce, rotate, and pulse independently. Budget for per-glyph text animation in the engine track; it is a disproportionate share of Balatro's perceived juice.
- Community extensions exist (m6x11cyrillic by natto games, m6x11plusPLUS on FontStruct) if localization ever matters.

**Opinion:** do NOT ship m6x11. It is now so identified with Balatro that using it reads as cloning (it is literally tagged "the Balatro font" everywhere). Use it as a placeholder during prototyping (license permits it, attribution required), then swap to a licensed font with similar metrics (tall x-height, chunky 1px-stroke pixel font) before any public screenshot.

### 1.2 Card sprite resolution conventions

- Each Balatro card sprite is **71×95 px at 1x** (142×190 at 2x). Subtracting the 1px (2px at 2x) transparent padding, visible art is **69×93 at 1x / 138×186 at 2x**. Sources: [Steam discussion "Pixel Art Dimensions"](https://steamcommunity.com/app/2379780/discussions/0/575995078023067463/), [Nexus Card Texture Template](https://www.nexusmods.com/balatro/mods/493?tab=docs).
- Modding convention (and the game's own convention): every asset ships in `assets/1x/` and `assets/2x/` so it works with and without "pixel smoothing." This dual-scale export is cheap to automate from Aseprite and we should copy it.
- Sprite sheets are browsable at [The Spriters Resource — Balatro](https://www.spriters-resource.com/pc_computer/balatro/) for studying composition (reference only, obviously not for use).

### 1.3 Shaders: GLSL fragment shaders in LÖVE

- Balatro is built in **LÖVE (love2d)** and ships its effects as plain GLSL `.fs` fragment shaders in `resources/shaders/` inside the executable (background.fs, splash.fs, plus the edition shaders — foil, holo, polychrome, negative — and a full-screen CRT shader). Documented by the Steamodded modding framework: [SMODS.Shader wiki](https://github.com/Steamodded/smods/wiki/SMODS.Shader-and-SMODS.ScreenShader), which notes you can unzip Balatro.exe and read `resources/shaders/` directly, and that `engine/sprite.lua → Sprite:draw_shader` shows the default uniforms ("externs") the game sends.
- Edition rarity weights in vanilla: foil 20, holographic 14, polychrome 3, negative 3 ([SMODS.Edition wiki](https://github.com/Steamodded/smods/wiki/SMODS.Edition)) — i.e., shader-effects are a rarity/economy signal, not decoration. Worth stealing as a concept: visual treatments = card tiers.
- The full-screen CRT effect (curvature + scanlines + fringe) is a **user-disableable setting** — the mobile community even patches it off for performance ([balatro-mobile-maker issue #174](https://github.com/blake502/balatro-mobile-maker/issues/174)). Plan the same: CRT as a post chain you can toggle, never baked into art.

### 1.4 Music & SFX model (for the audio half of "assets")

- Soundtrack by **LouisF** (Luis Clemente): effectively **5 variations of one theme in 7/4**, each 2:53, slowed to 70% in-game (≈4:07), crossfading between game areas ([Balatro Wiki — Music](https://balatrowiki.org/w/Music), [louisfmusic.com/balatro](https://louisfmusic.com/balatro)). One theme + soundfont/intensity variations = tiny content footprint, huge cohesion. This is the right model for a solo dev: commission ONE adaptive theme with stems, not a tracklist.
- SFX are card-physical (slides, flicks, chip clinks) plus pitched score blips that rise with combo escalation — the "casino energy."

---

## 2. Sourced assets — currently available, with licenses & prices (verified June 2026)

### 2.1 Pixel fonts

| Option | Price | License | Notes |
|---|---|---|---|
| [m6x11 / m6x11plus](https://managore.itch.io/m6x11) (Daniel Linssen) | Free | Free with attribution | Placeholder only — "the Balatro font" |
| Other managore fonts (m5x7, m3x6 etc. on [managore.itch.io](https://managore.itch.io/)) | Free | Free with attribution | m5x7 is a great monospace-feel terminal candidate |
| [Chevy Ray Pixel Font Megapack](https://chevyray.itch.io/pixel-font-megapack) — 175 fonts | $99 | Custom commercial license, unlimited projects, no font-file redistribution ([license repo](https://github.com/ChevyRay/pixel_font_megapack_license)) | Best quality/coverage in the space; singles ~$5–10 each; browse at [pixel-fonts.com](http://pixel-fonts.com/) |
| [somepx](https://somepx.itch.io/) individual fonts | $2–4 each | Personal+commercial, indie ≤$1M turnover, no redistribution/webfont/AI-training, attribution "kindly required" | Huge catalog, very Balatro-adjacent warmth |
| somepx [Humble Fonts – Free](https://somepx.itch.io/humble-fonts-free) | **now $50 min** (despite the name; verified 2026-06) | Personal+commercial, no redistribution, attribution appreciated | 5 fonts (Compass, Equipment, Expression, Futile, Matchup) |
| Kenney fonts (in [All-in-1](https://kenney.itch.io/kenney-game-assets) / [kenney.nl](https://kenney.nl/)) | Free | CC0 | Serviceable, less characterful |

**Recommendation:** budget ~$20–40 for 2–4 fonts: one chunky display pixel font (titles/big numbers), one compact UI font (5–7px grid for dense metrics), one monospace/tabular for the stats panels. Chevy Ray singles or somepx singles. The megapack at $99 is worth it the moment you've bought 3 singles and still feel constrained.

### 2.2 Card-frame / UI asset packs

| Pack | Price | License | Contents |
|---|---|---|---|
| [Kenney Playing Cards Pack](https://kenney.nl/assets/playing-cards-pack) | Free | CC0 | 270 assets, pixel cards in 3 sizes, dice, colored cards |
| [Kenney Boardgame Pack](https://kenney.nl/assets/boardgame-pack) | Free | CC0 | cards, chips, dice, tokens |
| [Kenney Game Assets All-in-1](https://kenney.itch.io/kenney-game-assets) | ~$30 | CC0 | 60k+ assets incl. UI packs — the canonical placeholder library |
| [Pixel Card UI (IndigoLay)](https://indigolay.itch.io/pixelcardui) | $4.99 base / $14.99 pro | Personal+commercial; no resale/repackaging/NFT/AI-dataset | 65 PNG sprites: modular frames, ribbons, badges, 5 color sets; Pro adds master PSDs. Base res 960×540 |
| [Pixel-art CCG-like Frames (Batareya)](https://batareya.itch.io/pixel-art-ccg-like-frames) | low $ | per-page | frame overlays, transparent backgrounds |
| [PixMeUp Casino Asset Pack](https://itch.io/game-assets/tag-balatro) | $12.99 | per-page | chips, cards, casino props (tagged "balatro") |
| [Colorful Playing Cards + Templates (Galactic Honey)](https://itch.io/game-assets/tag-balatro) | $10 | per-page | cards + empty templates |

There is a whole [itch.io "balatro" asset tag](https://itch.io/game-assets/tag-balatro) now — useful for placeholders, but anything from it that survives to ship will make us look derivative. Treat as scaffolding.

### 2.3 SFX — casino / chips / cards

| Source | Price | License | Contents |
|---|---|---|---|
| [Kenney Casino Audio](https://kenney.nl/assets/casino-audio) | Free | CC0 | **54 SFX: 23 card handling, 19 chip handling, 12 dice** (OGG). Also mirrored on [OpenGameArt](https://opengameart.org/content/54-casino-sound-effects-cards-dice-chips). This alone covers the placeholder tier completely. |
| [Sonniss #GameAudioGDC](https://gdc.sonniss.com/) | Free | Royalty-free, unlimited projects, no attribution ([license](https://sonniss.com/gdc-bundle-license/)) | GDC 2026 bundle is live (~7.5 GB); archive of prior years ≈200 GB ([archive](https://sonniss.com/gameaudiogdc/)). Note: no 2025 bundle was released (platform rebuild). |
| [Board Game SFX Pack (Duxmusic)](https://duxmusic.itch.io/board-game-sound-effects-pack-cards-tokens-capture-interaction-sfx) | ~$5 | per-page | card draw/shuffle, token, capture with variations |
| [itch casino+SFX tag](https://itch.io/game-assets/tag-casino/tag-sound-effects) | $0–15 | per-page | chip riffles, table ambience |

**SFX generators (free, for bespoke UI blips):** [ChipTone](https://sfbgames.itch.io/chiptone) (SFBGames, free, HTML5 — the best of the sfxr lineage), [jsfxr](https://sfxr.me/), Bfxr. The Balatro-style escalating score "ding ladder" is best made by generating one blip in ChipTone and pitch-stepping it in-engine.

### 2.4 Open-source shaders (CRT / foil / holo / dissolve)

**LÖVE:**
- [vrld/moonshine](https://github.com/vrld/moonshine) — chainable post-processing for LÖVE; **MIT, with the key effects public-domain (crt, scanlines, chromasep, glow, vignette, pixelate, filmgrain…)**. 16 effects. This is the entire Balatro post-stack (CRT curvature + scanline + chromatic fringe + bloom) for free. Older library but stable; LÖVE's shader API has not broken it.
- [Balatro-style background GLSL + working LÖVE snippet (gist by mar1lusk1)](https://gist.github.com/mar1lusk1/4677e482375bff4a01956107aef35699) — the swirling paint background, ready to run.

**Defold:** the official community ran a "[Recreate Balatro card effects in Defold](https://forum.defold.com/t/community-challenge-1-recreate-balatro-card-effects-in-defold/76854)" challenge — open-source results:
- [Dragosha/cards-fx-kit](https://github.com/Dragosha/cards-fx-kit) — **MIT (assets CC0)**: fake-3D perspective card tilt, dissolve, freeze, GUI materials, click/drag scripts. [HTML5 demo](https://dragosha.com/defold/cards-fx-kit/). The single most directly reusable repo found.
- [appsoluut/defold-balatro-card-burn-effect](https://github.com/appsoluut/defold-balatro-card-burn-effect) — card burn/dissolve shader.
- [schlista/Defold-Card-Shader-Sample](https://github.com/schlista/Defold-Card-Shader-Sample) — shimmer samples.
- [prismglue/balatro-fx](https://github.com/prismglue/balatro-fx) — card animation/feel.
- [indiesoftby/defold-dissolve-fx](https://github.com/indiesoftby/defold-dissolve-fx), [subsoap/defold-shader-examples](https://github.com/subsoap/defold-shader-examples), official [Shadertoy→Defold tutorial](https://defold.com/tutorials/shadertoy/) + [sample](https://github.com/defold/sample-shadertoy).

**Godot (portable GLSL logic):**
- [Balatro Foil card effect by Ritzy](https://godotshaders.com/shader/balatro-foil-card-effect/) — **CC0**, Godot 4.4; iridescent foil. The whole [godotshaders "balatro" tag](https://godotshaders.com/shader-tag/balatro/) is worth mining; godotshaders licenses are per-shader and frequently CC0/MIT.

**Shadertoy (caution):** [foil w3VGzm](https://www.shadertoy.com/view/w3VGzm), [foil 33c3zl](https://www.shadertoy.com/view/33c3zl), [polychrome 4cKfDc](https://www.shadertoy.com/view/4cKfDc), [Balatro website bg XXjGDt](https://www.shadertoy.com/view/XXjGDt), [backgrounds XXtBRr](https://www.shadertoy.com/view/XXtBRr). **Shadertoy's default license is CC BY-NC-SA 3.0 — non-commercial.** Use Shadertoy strictly as a study reference; take implementations only from explicitly-licensed repos (above) or re-implement. Same warning for libretro CRT shaders (GPL).

LOVE2D shader learning path: [LÖVE beginner's guide to shaders](https://blogs.love2d.org/content/beginners-guide-shaders) — recommended by the Steamodded wiki itself.

### 2.5 Particle / juice references

- [Juice it or lose it](https://www.youtube.com/watch?v=Fy0aCDmgnxg) (Jonasson & Purho) and [The Art of Screenshake](https://www.youtube.com/watch?v=AJdEqssNZ-U) (Jan Willem Nijman, Vlambeer) — the canon. Good annotated notes: [russmatney.com/posts/notes/juicy](https://russmatney.com/posts/notes/juicy/).
- Balatro-specific juice anatomy: per-glyph bouncing text, card wobble on hover (fake-3D tilt — see Dragosha kit), score-counter tick-up with pitch-rising blips, easing on EVERYTHING (LÖVE devs typically use rxi/flux or similar tween libs; Defold has `go.animate`/`gui.animate` built in with easing curves).

---

## 3. Tooling

| Tool | Price | Use |
|---|---|---|
| [Aseprite](https://www.aseprite.org/buy/) | $19.99 (Steam/itch/Humble; v1.x series, updates through v1.9) | The pixel-art editor. Indexed-palette mode, tags, slices, and a **CLI** (`aseprite -b`) that exports sprite sheets + JSON — wire it into the build so `.aseprite` files are the source of truth and 1x/2x PNGs are generated artifacts (mirroring Balatro's 1x/2x convention). |
| [Lospec palette list](https://lospec.com/palette-list) | Free | Palettes downloadable as `.ase`/`.gpl` straight into Aseprite. Shortlist: [Resurrect 64](https://lospec.com/palette-list/resurrect-64) (Kerrie Lake — rich, Balatro-adjacent saturation), [Apollo](https://lospec.com/palette-list/apollo) (46c, sophisticated), [SLSO8](https://lospec.com/palette-list/slso8) (8c, moody, good for a backroom direction). Pick ONE master palette ≤64 colors; per-direction sub-palettes. |
| [ChipTone](https://sfbgames.itch.io/chiptone) / [jsfxr](https://sfxr.me/) | Free | UI blips, score dings |
| [Bosca Ceoil Blue](https://yurisizov.itch.io/boscaceoil-blue) (Yuri Sizov's modern port of Terry Cavanagh's tool) | Free | Fast music sketching; exports WAV/MIDI/XM |
| [FamiStudio](https://famistudio.org/) | Free | If the music direction goes chip-flavored |
| Reaper | $60 (discounted personal/small-biz license) | Layering/mastering SFX variants |

**AI-assisted concepting (author-time only):**
- [Retro Diffusion Aseprite extension](https://astropulse.itch.io/retrodiffusion) (Astropulse) — **$65 one-time (Lite $20)**, no subscription; model trained on licensed art with artist consent, which makes it the only defensible option provenance-wise. Generates pixel art inside Aseprite + smart color reduction.
- [PixelLab](https://www.pixellab.ai/) — browser/Aseprite plugin, freemium, **$9–50/mo** tiers; stronger at animation/rotations.
- **Position:** AI tools are for mood boards, thumbnail exploration, and palette studies at author time. Final shipped art is hand-made or commissioned. The pixel-art audience (and Balatro's audience specifically) is openly hostile to AI-generated assets; getting flagged would cost more than the art budget saved. Retro Diffusion's licensed-data provenance is the fallback if any AI-assisted output ever ships.

---

## 4. Pragmatic solo-dev pipeline

### Tier 0 — Placeholder (week 1, ~$0–25)
- Cards/chips/UI: Kenney CC0 packs (+ All-in-1 if desired, ~$30).
- Font: m6x11 (attributed) or Kenney CC0 fonts — swap before any public material.
- SFX: Kenney Casino Audio CC0 + ChipTone blips.
- Shaders: moonshine chain (crt+scanlines+chromasep+glow) in LÖVE, or Dragosha cards-fx-kit in Defold.
- Goal: prove the loop feels good with zero bespoke art. Balatro's own first cards were programmer pixel art (LocalThunk's first-ever pixel art, per [the Balatro Timeline](https://localthunk.com/blog/balatro-timeline-3aarh)).

### Tier 1 — Owned identity (months 1–3, ~$150–400)
- Buy 2–4 fonts (Chevy Ray / somepx singles, ~$20–40).
- Buy 1–2 modular card-frame packs as a base to repaint ($5–25).
- Hand-make (or AI-concept → hand-finish) the master card template at 1x/2x, the 8–12 core component icons, and one background shader.
- Lock the master palette (Lospec) and the art-direction choice (§5).

### Tier 2 — Commission (when the loop is validated, ~$1.5k–5k)
- Where: r/gameDevClassifieds, direct DM to itch.io pixel artists whose packs you bought (they freelance), X/Bluesky #pixelart portfolios, ArtStation. Vet for *card/UI* work specifically, not character art.
- Costs (2025–26 ballparks, [voxillustration guide](https://voxillustration.com/blog/concept-art-pricing-for-game-development/), board-game forums): hourly $25–100; painted card illustration averages **$75–85/card** on ~$3k card-game budgets; small pixel sprites/icons commonly $20–60 each; a style bible / key-art pass $300–800.
- Sequence: commission a **style bible first** (1 hero card + 1 screen mock + palette), then batches of component icons (they're the bulk: dozens of hooks/angles/formats/offers), then juice polish (foil masks, particle sheets).
- One adaptive music theme with stems (Balatro/LouisF model): typically $500–1.5k commissioned indie rate. One theme, many intensities — cheap and cohesive.

### Production conventions to adopt now
- **Sprite source of truth:** `.aseprite` files in repo; CI/CLI export to `assets/1x/` + `assets/2x/` (Balatro convention).
- **Card sprite size:** start at **71×95-class** (69×93 visible + 1px pad) — proven readable on phones by Balatro mobile. If our cards need a metric strip, go taller (e.g. 71×106) rather than denser.
- **All effects are shaders + tweens on flat sprites** — no baked animation frames for juice. Foil/holo/dissolve as small `.fs` files with documented uniforms (copy the SMODS convention: shader key == filename == GLSL name).
- **CRT chain togglable** from day 1 (accessibility + mobile battery).

---

## 5. Art-direction proposals (differentiating from Balatro's poker table)

Balatro = poker felt + CRT + pixel cards. We keep the *grammar* (chunky pixel cards, CRT warmth, casino energy) but move the *setting* to the ad industry. Three directions:

### Direction A — "Late-Night Cable" (broadcast desk neon) — RECOMMENDED
You run ads on the air; the playfield is a monitor wall in a 1990s master-control room.
- **Palette:** deep indigo/charcoal base, phosphor magenta + cyan accents, amber warning lights, white-hot highlights (sub-palette of Resurrect 64).
- **Type:** chunky rounded display font for show-titles; condensed tabular numerals for tickers.
- **Motifs:** "ON AIR" lamps for live ads, lower-third chyrons as metric readouts, SMPTE test bars for empty slots, vectorscope/waveform widgets as charts, VHS tracking-noise dissolve when an ad fatigues, channel-change flicker between audiences.
- **Why it wins:** CRT shader becomes *diegetic* (you're literally watching monitors) instead of borrowed Balatro styling; "watch your ad perform live" maps perfectly to broadcast; warm + nostalgic + reads instantly on a phone.

### Direction B — "Terminal Floor" (trading-floor terminal)
Ads are instruments; playing one opens a position; the account is a Bloomberg-like phosphor terminal.
- **Palette:** near-black, amber #FFB000 + phosphor green, alarm red / gain green deltas (SLSO8-adjacent moodiness).
- **Type:** monospace pixel font (m5x7-class) everywhere; split-flap/LED-segment numerals for ROAS.
- **Motifs:** candlestick-ish spend charts, ticker tape of conversions, klaxon + red flash on overspend, "margin call" energy when budget runs hot.
- **Risk:** cold and masculine-coded; metrics-forward but the *cards* fight the terminal frame. Best harvested for the deep-stats screens inside Direction A.

### Direction C — "Print Shop" (Madison-Avenue halftone)
A mid-century agency bullpen: ads are paste-up boards, performance comes back as printed reports.
- **Palette:** cream paper, ink black, CMYK primaries with deliberate misregistration; coffee-ring browns.
- **Type:** woodtype-flavored display pixel font + typewriter body.
- **Motifs:** halftone-dot shading, rubber stamps (APPROVED / KILL / FATIGUED), spot-foil stamping as the rare-card effect, paper-burn/halftone dissolve, pin-board with red string for audience insights.
- **Risk:** gorgeous and ownable but period-locked; weaker fit for "real-time live" fantasy.

**Rejected: "Casino Backroom Analytics."** Green felt + chips + smoky backroom is the obvious move and exactly why it's wrong — it's Balatro's table with a spreadsheet on it. Keep the casino in the *feel* (chip-clink SFX, escalating dings, foil rarity) and out of the *set dressing*.

---

## 6. Sources

- https://managore.itch.io/m6x11
- https://x.com/LocalThunk/status/1739882509826248882
- https://fontsinuse.com/uses/65816/balatro-computer-game
- https://steamcommunity.com/app/2379780/discussions/0/575995078023067463/
- https://www.nexusmods.com/balatro/mods/493?tab=docs
- https://www.spriters-resource.com/pc_computer/balatro/
- https://github.com/Steamodded/smods/wiki/SMODS.Shader-and-SMODS.ScreenShader
- https://github.com/Steamodded/smods/wiki/SMODS.Edition
- https://github.com/blake502/balatro-mobile-maker/issues/174
- https://localthunk.com/blog/balatro-timeline-3aarh
- https://balatrowiki.org/w/Music
- https://louisfmusic.com/balatro
- https://chevyray.itch.io/pixel-font-megapack
- https://github.com/ChevyRay/pixel_font_megapack_license
- http://pixel-fonts.com/
- https://somepx.itch.io/humble-fonts-free
- https://kenney.nl/assets/playing-cards-pack
- https://kenney.nl/assets/casino-audio
- https://kenney.nl/assets/boardgame-pack
- https://kenney.itch.io/kenney-game-assets
- https://opengameart.org/content/54-casino-sound-effects-cards-dice-chips
- https://gdc.sonniss.com/
- https://sonniss.com/gdc-bundle-license/
- https://sonniss.com/gameaudiogdc/
- https://duxmusic.itch.io/board-game-sound-effects-pack-cards-tokens-capture-interaction-sfx
- https://itch.io/game-assets/tag-casino/tag-sound-effects
- https://sfbgames.itch.io/chiptone
- https://sfxr.me/
- https://github.com/vrld/moonshine
- https://gist.github.com/mar1lusk1/4677e482375bff4a01956107aef35699
- https://forum.defold.com/t/community-challenge-1-recreate-balatro-card-effects-in-defold/76854
- https://github.com/Dragosha/cards-fx-kit
- https://github.com/appsoluut/defold-balatro-card-burn-effect
- https://github.com/schlista/Defold-Card-Shader-Sample
- https://github.com/prismglue/balatro-fx
- https://github.com/indiesoftby/defold-dissolve-fx
- https://github.com/subsoap/defold-shader-examples
- https://defold.com/tutorials/shadertoy/
- https://godotshaders.com/shader/balatro-foil-card-effect/
- https://godotshaders.com/shader-tag/balatro/
- https://www.shadertoy.com/view/w3VGzm · /view/33c3zl · /view/4cKfDc · /view/XXjGDt · /view/XXtBRr
- https://blogs.love2d.org/content/beginners-guide-shaders
- https://www.aseprite.org/buy/
- https://lospec.com/palette-list/resurrect-64 · /palette-list/apollo · /palette-list/slso8
- https://yurisizov.itch.io/boscaceoil-blue
- https://astropulse.itch.io/retrodiffusion
- https://www.pixellab.ai/
- https://indigolay.itch.io/pixelcardui
- https://batareya.itch.io/pixel-art-ccg-like-frames
- https://itch.io/game-assets/tag-balatro
- https://voxillustration.com/blog/concept-art-pricing-for-game-development/
- https://www.youtube.com/watch?v=Fy0aCDmgnxg (Juice it or lose it)
- https://www.youtube.com/watch?v=AJdEqssNZ-U (The Art of Screenshake)
- https://russmatney.com/posts/notes/juicy/
