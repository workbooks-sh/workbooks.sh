# Balatro Deconstructed — North-Star Research for Addendum

**Track:** balatro | **Date:** 2026-06-05 | **Status:** verified against live web sources + decompiled-source analyses

> Scope: (1) tech/architecture, (2) game-loop anatomy & math, (3) juice catalog, (4) mobile port, (5) transferability to a real-time live-manager game, plus localthunk's design philosophy. Confidence flags: **[HIGH]** verified from primary/multiple sources, **[MED]** single good source or strong community consensus, **[LOW]** inference/unverified.

---

## 0. Current status snapshot (June 2026)

- Balatro shipped Feb 20, 2024; 5M+ copies by Jan 2025 (TGA wins: Best Independent, Best Debut Indie, Best Mobile). No newer official milestone found. **[HIGH]**
- The big content update **1.1 is still unreleased** — delayed out of 2025 into "2026, done when it's done." localthunk confirmed in Feb 2026 ("Yes I'm still working on 1.1"). He works hobbyist pace (~few hours/day) explicitly to avoid the crunch that burned him out. **[HIGH]**
- LÖVE **11.5 "Mysterious Mysteries" (Dec 2023) is still the latest stable release**; 12.0 "Bestest Friend" remains unreleased as of June 2026 (nightly builds only, though commercial games have shipped on it). Verified via GitHub releases API. **[HIGH]**
- Modding ecosystem is alive: **lovely-injector v0.9.0** (Jan 2026, Rust, MIT) and **Steamodded 1.0.0-beta-1620a** (Apr 20, 2026). **[HIGH]**

---

## 1. Tech: what Balatro actually is under the hood

### 1.1 Platform & how we know

- Built on **LÖVE (Love2D) 11.5** + Lua. The shipped binary literally answers `--version` with `LOVE 11.5 (Mysterious Mysteries)`. Desktop builds are a stock-ish LÖVE fused executable; **the entire commented Lua source ships inside** — rename `Balatro.exe` → `.zip` (or open the `.love` in `Balatro.app`) and you can read all of it. Not open source (all-rights-reserved; modding rules permit reading/patching, not redistribution of code/assets). **[HIGH]**
- ~**30,000 lines of Lua** excluding localization. **[HIGH]** (debug.blog count)
- Mobile/Apple Arcade builds (`com.playstack.balatroarcade`) are a **custom LÖVE fork with `love.platform.*` extensions** (e.g. `love.platform.earlyInit`) for native services — haptics, Game Center, platform auth. Discovered by people trying to run the Arcade build under stock love2d. **[HIGH]**
- localthunk reused an engine layer he'd built for an earlier prototype ("Autohike"); LÖVE specialist **Maarten De Meyer** is credited by localthunk for instrumental porting work. **[MED]**

### 1.2 Codebase shape: a flat, global, god-function monolith — on purpose

File layout (from decompiled source mirrors):

```
Balatro/
├── main.lua            # love.run with FPS cap, canvases
├── conf.lua
├── globals.lua         # the G mega-global: settings, timers, states, colors
├── game.lua            # ~3,600 lines: Game object, state machine, per-state update fns
├── card.lua            # ~4,700 lines: Card class incl. ALL joker logic (calculate_joker)
├── cardarea.lua        # hand/jokers/shop containers
├── blind.lua / back.lua / tag.lua / challenges.lua / card_character.lua
├── engine/             # reusable layer (~15 files)
│   ├── object.lua      # tiny OOP base
│   ├── node.lua        # scene graph, hover/collision, draw (389 ln)
│   ├── moveable.lua    # T/VT transform easing, juice, attachments (517 ln)
│   ├── sprite.lua, animatedsprite.lua, particles.lua
│   ├── text.lua        # DynaText per-letter animated text
│   ├── ui.lua          # UIBox/UIElement retained-mode UI (1,054 ln)
│   ├── controller.lua  # mouse/kb/gamepad/touch unified (1,382 ln)
│   ├── event.lua       # EventManager + Event (the scheduling spine)
│   ├── sound_manager.lua  # audio on its own thread
│   ├── save_manager.lua, http_manager.lua, string_packer.lua, profile.lua
├── functions/          # "god function" drawers
│   ├── common_events.lua, state_events.lua, button_callbacks.lua
│   ├── misc_functions.lua, UI_definitions.lua
├── localization/
└── resources/          # textures (cards are 71×95 px atlases), sounds, shaders/*.fs
```

Architectural facts an indie should internalize:

- **One global `G` is the single source of truth** (G.GAME run state, G.STATE/G.STATES state machine, G.E_MANAGER, G.FUNCS callback registry, G.UIDEF UI builders, G.SETTINGS, G.TIMERS). Files are organizational drawers, not modules — `require` just executes into globals; everything can call everything. **[HIGH]**
- **God functions are load-bearing.** `Card:calculate_joker` is a multi-thousand-line if-chain handling 150 jokers. The famous April 2024 Twitter dunk-fest concluded, on inspection, that it's *fine*: readable, fast enough, optimized for rapid content prototyping over abstraction ("Load-bearing Tomato" essay). The lesson is not "write spaghetti," it's **optimize for iteration speed on content, because content volume is the game**. **[HIGH]**
- The engine/ layer is genuinely clean and reusable — the mess is quarantined in game-logic land. That split (tiny polished kernel + sloppy fast content layer) is the actual architecture. **[HIGH, opinion]**

### 1.3 Node → Moveable: the object system that makes everything feel physical

- `Node` (extends `Object`): scene-graph node with children, hover/collision detection, draw hooks. `Moveable` (extends Node) is where the magic lives. **[HIGH]**
- Every Moveable has **two transforms: `T` (target: x, y, w, h, r, scale) and `VT` (visible)**. Game logic writes `T`; every frame `VT` chases `T` through an exponentially-smoothed velocity:
  `self.velocity.x = G.exp_times.xy*self.velocity.x + (1-G.exp_times.xy)*(self.T.x - self.VT.x)*35*dt`
  with snap-to-target under a 0.01 threshold. **Nothing in Balatro teleports; everything glides with slight overshoot, for free, everywhere.** This is the single highest-leverage idea to steal. **[HIGH]**
- **`juice_up(amount, rot_amt)`** — the universal "punch" primitive. Sets a 0.4s damped sine on scale and rotation:
  `juice.scale = scale_amt * sin(50.8*(t - start)) * max(0, ((end_t - t)/(end_t - start))^3)` (rotation same with power 2). Called on hover, score, sell, seal, level-up — one function, the entire game's tactility. **[HIGH]**
- **Major/Minor attachment roles with per-channel bonds** (`xy_bond`, `wh_bond`, `r_bond`, `scale_bond`, each Strong/Weak): cards are "minors" glued to card-areas/owners with rotated offsets; weak bonds let a channel lag elastically. Declarative parenting → fan layouts, drag-reorder, shop rows all fall out of one system. **[HIGH]**
- **`pinch`**: eases width/height to 0 and back — that's the card-flip squash. **[HIGH]**
- **Shadows are fake-parallax children**: `shadow_parrallax.x = (T.x + T.w/2 - ROOM.w/2)/(ROOM.w/2)*1.5` — shadow offset depends on horizontal position relative to screen center, plus `shadow_height`. Cheap depth that reads as a lamp over a card table. **[HIGH]**
- **Card tilt pseudo-3D**: each card keeps `tilt_var = {mx, my, dx, dy, amt}` from cursor position/velocity plus a constant `ambient_tilt = 0.2` idle sway (the table never sleeps). Tilt feeds both a small 2D rotation and shader uniforms so foil/holo/polychrome shine moves with the "angle." There is no 3D — it's rotation + lighting-shift + parallax shadow. **[HIGH on mechanism, MED on exact uniform plumbing]**

### 1.4 The event/timer queue: the real secret of Balatro's feel

`G.E_MANAGER` (engine/event.lua) is a sequential event scheduler, exhaustively documented by the community (WilsontheWolf gist):

- `G.E_MANAGER:add_event(Event({...}), queue, front)` with **trigger types**: `immediate`, `after` (delay), `condition` (poll `ref_table/ref_value/stop_val`), `ease` (tween a numeric field over time — lerp/elastic/quad), `before`. Event functions return `true` when done, `false` to re-run next frame. **[HIGH]**
- **`blocking`/`blockable` booleans** (both default true) make the base queue a strict sequence: each event holds the line until done. Queues: `base`, `other`, `unlock`, `tutorial`, `achievement`; `front=true` preempts. `delay` is scaled by the **game-speed setting (1×–4×)** — the player can compress the ceremony. Timers: REAL vs TOTAL (pause-aware). **[HIGH]**
- **This queue IS the scoring drum-roll.** When you play a hand, the game resolves all math conceptually instantly, but feedback is enqueued as a chain of tiny blocking events: ping card 1 (juice_up + sound + chip counter eases up) → ping card 2 → … → each joker bounces left-to-right with running totals → mult × chips slam together. Numbers on screen are eased (`trigger='ease', ref_table=G.GAME, ref_value='chips'`), never set. The result: arithmetic becomes a slot-machine payout reveal. **[HIGH]**

### 1.5 Shaders & rendering

- Pixel-art assets (cards 71×95 px) on canvases, scaled; a **full-screen CRT pass** (CRT.fs) applies scanline, curvature, chromatic-aberration/bloom-ish unification — intensity is a user slider, off-able (accessibility/motion). The CRT pass is what glues chunky pixel art + vector-ish UI into one cohesive object. **[HIGH on existence/role, MED on exact uniform list]**
- **background.fs**: the slow swirling-paint vortex behind everything; hue keyed to game state (boss = menacing red, shop calm, etc.). Constant ambient motion = casino-table energy. Widely cloned (godotshaders has a whole "balatro" tag; LÖVE GLSL recreations exist as gists). **[HIGH]**
- **Edition shaders**: `foil` (metallic blue waves), `holo` (rainbow sheen), `polychrome` — per balatrowiki, polychrome "takes the distance of a pixel from a randomly determined point and hue shifts it based on a time variable and what angle the card is looked at (where the mouse cursor is hovering)" — i.e., **tilt drives the lighting model**. Plus `negative`, `debuff`, `dissolve` (card burn-away on destruction), `flame` (score fire), booster/voucher variants. Shaders instead of art assets: HN thread confirms the motivation was reducing asset count/size. **[HIGH]**
- main.lua: custom `love.run` with an FPS cap (`love.timer.sleep(1/G.FPS_CAP - run_time)`), `G.CANVAS` (+ conditional `G.AA_CANVAS` on high-DPI Windows), crash-reporting HTTP thread. **[HIGH]**

### 1.6 Sound architecture

- **Audio runs on its own LÖVE thread**, fed via channels (`CHANNEL:demand()`), so audio never hitches with game logic. **[HIGH]**
- **Music = 5 stems** (composer Luis Clemente / "LouisF", hired via Fiverr), all in 7/4, same length, played in parallel and **crossfaded by exponential volume smoothing** (`current_volume = target*(dt*3) + (1-dt*3)*current_volume`) keyed to state (main/shop/booster/boss). Tracks are authored at one tempo and slowed to 70% in-game. **[HIGH]**
- **Global pitch modulation**: `sound:setPitch(original_pitch * pitch_mod)` — on defeat the whole mix slows/drops pitch; ambient layers duck/swell by state. **[HIGH]**
- **Rising-pitch scoring**: concrete examples from source — `play_sound('card1', 0.85 + percent*0.2/100, …)` (pitch climbs as the value/position climbs), `play_sound('multhit2', 0.9 + 0.2*math.random(), 0.7)` (humanized mult hits), `chips2`/`coin1` ticks under eased counters, staggered `tarot1` + triple `juice_up(0.8, 0.5)` on hand level-ups. The "pitch rises as the tally climbs" trick is real and cheap: pitch = base + k·progress. **[HIGH]**

### 1.7 Modding ecosystem (proof the architecture is steal-able)

- **lovely-injector** (Rust, MIT, v0.9.0 Jan 2026): generic runtime Lua injector for LÖVE games — detours the Lua loader in-process and applies **TOML-defined patches** (pattern, regex, copy, module) to source as it loads. Non-destructive, works Win/macOS/Linux/Proton. **[HIGH]**
- **Steamodded (smods)** (1.0.0-beta-1620a, Apr 2026): the de-facto modding framework on top of lovely; provides typed APIs for jokers/decks/etc. (its `lsp_def/vanilla.lua` is incidentally the best public type-annotated map of Balatro's class hierarchy: Object → Node → Moveable → {Sprite, DynaText, UIBox/UIElement, Card}). Also Balamod, Thunderstore/Nexus communities. **[HIGH]**
- Takeaway: because the game is readable Lua with one global and data-ish content functions, a huge mod scene bootstrapped itself with zero official tooling. If Addendum ships as Lua, we inherit this possibility space (and its piracy/readability tradeoff — Balatro's source being readable cost localthunk nothing commercially). **[HIGH, opinion]**

---

## 2. Game-loop anatomy & math

### 2.1 Run structure

- A run = **8 antes**; each ante = **Small Blind → Big Blind → Boss Blind**. Small/Big are skippable; Boss is mandatory and mutates rules (debuffs clubs, caps hand size, hides cards…). Within a blind: default **4 hands, 3 discards**; play 5-card poker hands until you beat the chip target or fail. Between blinds: **shop** (2 jokers/consumables, 2 booster packs, 1 voucher; reroll $5, +$1 each). **[HIGH]**
- **Blind targets (White Stake), antes 1–8: 300, 800, 2,000, 5,000, 11,000, 20,000, 35,000, 50,000**, with Small=1×, Big=1.5×, Boss=2× the ante base. Past ante 8 (Endless): `amount = floor(a*(b+(k*c)^d)^c)` with `a=50,000, b=1.6, k=0.75, c=ante-8, d=1+0.2*(ante-8)`, rounded to 2 significant digits — i.e., super-exponential. Higher stakes scale faster (Green/Purple reach 100k/200k at ante 8). **[HIGH]**

### 2.2 Why chips × mult feels so good (the load-bearing math)

- Score per hand = **(base chips of hand level + card chips + joker chips) × (base mult + joker mult, then ×mult jokers multiply)**. Two axes that multiply means *every* investment on one axis is amplified by the other — the player constantly experiences compounding, not addition. **[HIGH]**
- There's a clean **three-tier escalation: +chips < +mult < ×mult**. Community scaling guides confirm ×mult jokers are mathematically mandatory by ante 8; flat bonuses carry early game. Planet cards level individual poker hands (raising base chips AND mult — both axes at once, which is why they feel great). **[HIGH]**
- Targets grow exponentially, so the *build* must grow multiplicatively — the game forces you to graduate from arithmetic to multiplication, which reads emotionally as "going infinite." Endless mode scores hit scientific notation; the community celebrates "naneinf" (overflow) runs. **[HIGH/MED]**
- localthunk on its origin: "I really don't know where this idea came from but it seemed very natural for a scoring system." It was in the prototype before jokers existed. The lesson: **pick the multiplication structure first; content hangs off it.** **[HIGH]**

### 2.3 Economy: interest is the skill-check

- Rewards: **Small $3 / Big $4 / Boss $5** (+$8 showdown), **+$1 per unused hand**, and crucially **interest: $1 per $5 held, capped at $5/round (i.e., $25 banked)**; vouchers raise the cap. Sell-back ~half cost; Credit Card joker allows −$20 debt. **[HIGH]**
- This creates the central tension: **spend now for power vs. hold $25+ for compounding income**. Skilled play is mostly economic discipline — strikingly close to paid-media budget management (don't torch the budget on day one; let winners compound; know when to break the bank for a scaling opportunity). Directly portable to Addendum. **[HIGH, opinion]**
- **Skip tags (24 of them)**: skipping a Small/Big blind forfeits its cash/shop for a tag (free packs, joker editions, $ effects, Double Tag copies the next tag…). It converts "skip a fight" into a tempo-vs-value gamble and a build-direction bet. **[HIGH]**

### 2.4 Joker build-around identity

- **150 jokers, 5 slots** (negative edition = +1 slot). Jokers are the run's identity: synergy archetypes (flush, face-cards, retriggers, economy, mult-scaling, deck-thinning). Rarity tiers + editions (foil +50 chips, holo +10 mult, polychrome ×1.5 mult) make even a duplicate joker exciting — **the modifier system multiplies content without new content**. **[HIGH]**
- **Unlocks broaden, never strengthen**: locked jokers/decks/stakes gate discovery and give long-horizon goals, but there is **no meta-progression power** — every run is self-contained, no permanent upgrades, no currencies between runs. The compulsion is "next run I'll play better," not "next run my numbers are bigger." This is a deliberate stance and a core lesson. **[HIGH on the design fact; MED on intent — inferred from interviews, not a single manifesto post]**

---

## 3. Juice catalog — concrete, stealable techniques

1. **Two-transform easing (T/VT)** — every object eases toward its target with velocity + overshoot; nothing snaps. One system, global tactility. **[HIGH]**
2. **`juice_up` damped-sine punch** — 0.4s scale/rotation wobble on every interaction; parameterized per intensity (`0.3,0.5` hover → `0.8,0.5` level-up). **[HIGH]**
3. **Screen shake as decaying accumulator** — `G.ROOM.jiggle += 0.7` on big hits; per-frame `jiggle *= (1-5*dt)`; applied as high-frequency rotation `0.002*jiggle*sin(39.913*t)` layered over a permanent idle sway `0.001*sin(0.3*t)`; scaled by a user setting. The room is literally never perfectly still. **[HIGH]**
4. **Cursor-tracked card tilt + ambient wobble** — `tilt_var` from mouse, `ambient_tilt` at rest; tilt drives edition-shader lighting so foil/holo shine moves "physically." **[HIGH]**
5. **Fake-parallax drop shadows** — shadow child offset by position relative to screen center; reads as table depth for ~3 lines of math. **[HIGH]**
6. **Pinch card flips** — width eases to 0, swap face, ease back; no 3D needed. **[HIGH]**
7. **DynaText** — per-letter animated text (pop-in, pulse, quiver, float). Score labels and hand names physically react to value changes. **[HIGH]**
8. **Eased number counters** — chips/dollars are tweened via `ease` events (~0.3–0.5s) with tick sounds (`chips2`, `coin1`); money and score are *experienced as motion*. **[HIGH]**
9. **Event-queue payout choreography** — scoring resolves as a sequenced drum-roll: per-card pings → per-joker bounces with running totals → final slam. The queue's blocking semantics ARE the pacing design. **[HIGH]**
10. **Rising pitch with progress** — `0.85 + progress*0.2` style pitch math on scoring ticks; randomized ±10% pitch on hits to avoid machine-gun monotony. **[HIGH]**
11. **Adaptive music stems** — equal-length 7/4 stems crossfaded by state via exponential smoothing; defeat = global pitch/tempo drop (`setPitch(original*pitch_mod)`). **[HIGH]**
12. **Score-on-fire threshold** — flame shader ignites the score box when a hand vastly outscores expectation; intensity scales; was a friend's suggestion localthunk initially rejected. **[HIGH]**
13. **Ambient background shader** — slow swirling paint, state-keyed colors; plus full-screen CRT pass (scanlines/curvature/aberration, user-adjustable) that unifies all art into one lit object. **[HIGH]**
14. **Particles** — chip bursts on scoring, sparkles on editions, money confetti (engine/particles.lua). **[HIGH]**
15. **Game-speed multiplier (1×–4×)** — all event delays scale; experts compress ceremony without losing it. Respecting mastery keeps the loop tight for hundreds of hours. **[HIGH]**
16. **Native haptics on mobile** — custom LÖVE fork; per-interaction haptic taps reinforce the card-feel on glass. **[MED]**

**The meta-lesson:** Balatro's juice is ~6 small systems (ease, juice, jiggle, tilt, DynaText, event queue) applied *universally*, not hundreds of bespoke animations. Build the six primitives once; every feature inherits feel.

---

## 4. The mobile port

- **Shipped Sept 26, 2024** on iOS + Android at **$9.99** (vs $14.99 desktop), plus **Balatro+ on Apple Arcade** (incl. macOS/tvOS) same day. Publisher Playstack; no MTX, no ads. Won **Best Mobile Game, TGA 2024**. Port is the same Lua codebase on a custom LÖVE runtime with `love.platform` native extensions. **[HIGH]**
- **What it gets right** (Engadget: "an almost perfect mobile port"; TouchArcade: "superb"):
  - Full feature parity with desktop; instant boot; flawless perf.
  - Touch drag-and-drop of cards is *more* satisfying than mouse — several reviewers now prefer mobile.
  - Cloud saves, multiple profiles, High Contrast Cards accessibility option.
  - Excellent on tablets/foldables — the card table density fits big phones fine.
- **What it gets wrong / friction** **[HIGH, multi-review consensus]**:
  - **Landscape-only. No portrait mode.** Repeated complaint; kills one-handed/commute play. (Still true as of the 2024–2025 review cycle; no portrait update found.)
  - Touch is implemented as **finger-as-cursor** (a port of mouse semantics), not rethought touch idioms (148Apps).
  - Small text/touch targets on phones; **skip-button placement causes accidental taps** (Engadget); foldable layouts don't use extra vertical space.
  - Anecdotal but real: it *looks* like gambling over your shoulder on a train.
- **Implication for Addendum:** Balatro proved premium, dense, numbers-heavy card UIs work on phones — but it's a *ported* layout. A **portrait-first, thumb-reach-first** live-manager design is open territory Balatro never claimed. Its mobile flaws are our spec. **[opinion]**

---

## 5. Transfer analysis: turn-based Balatro → real-time live-manager

### Transfers cleanly (steal these)

1. **The entire juice stack** (§3) is loop-agnostic. T/VT easing, juice_up, eased counters, pitch-rising ticks, parallax shadows — all apply to a live dashboard of running ads exactly as well as to a hand of cards.
2. **Two-axis multiplicative scoring.** chips×mult ⇒ e.g. *reach × resonance* (or hook-rate × conversion). Keep exactly two visible multiplying axes with a third rare "×" tier on top. The compounding feel, not poker, is the engine.
3. **Interest/banking economy.** Maps 1:1 to ad-budget discipline and compounding ROAS. Balatro shows players will learn real financial restraint if the cap ($25) is legible.
4. **Skip tags as tempo bets** ⇒ "sit out this trend/brief, bank budget, take a draft pick instead."
5. **Build-around identity in a small slot count.** 5 joker slots ⇒ a small set of account-wide modifiers (brand voice, creator roster, pixel/data infrastructure) that make each run a thesis.
6. **Editions/modifiers multiply content.** Foil/holo/polychrome ⇒ variant treatments of the same creative-component card (UGC version, founder-face version…). Cheap content explosion.
7. **No meta-progression power; unlocks broaden.** Keeps every run honest and the skill real — critical for Addendum's "stealth training tool" ambition, since carried power would corrupt the lesson that *pattern-reading* is the progression.
8. **Self-contained-run philosophy + premium model.** localthunk's anti-FOMO/anti-gambling stance is brand-aligned for a game about *resisting* dopamine-merchant tactics. (See §6.)
9. **Readable Lua + data-driven content** ⇒ free modding ecosystem potential.

### Load-bearing only in turn-based — must be redesigned

1. **The blocking event queue assumes the world waits.** Balatro's drum-roll works because nothing happens until the tally ends. In real time, metrics tick continuously — naively streaming numbers will dissolve the payout moment entirely. **The reveal must be manufactured**: scheduled "close-outs" (end of day/flight), creative-review beats, or a "results are in" envelope the player opens. Balatro's own non-blocking `other` queue is the architectural hint: celebrations layered over a live simulation rather than halting it.
2. **Discrete failure gates.** Blinds give clean targets and clean deaths every ~3 minutes. A live manager needs equivalent periodic gates (client retention reviews, billing cycles, "hit CPA by Friday") or tension flattens into ambient anxiety.
3. **Infinite staring time.** Balatro is fully pausable contemplation; hidden-information reading is leisurely. Real-time pressure devalues dense UI — Addendum's data readouts must be *more* glanceable than Balatro's, with an explicit pause/slow-mo as a core verb (cf. Mini Motorways), not an accessibility afterthought.
4. **One skill moment (hand selection).** Balatro compresses all agency into "which 5 cards." Real-time spreads agency thin; we must keep deploy/kill/iterate decisions chunky and irreversible-ish so each one carries Balatro-grade weight.
5. **Score-as-spectacle math.** Exponential blind targets work because a run is 30–60 min and ends. A persistent live sim can't inflate forever; fatigue/decay (which Addendum already plans) is the right counter-force — Balatro has no decay, which is precisely why it must end at ante 8.

---

## 6. localthunk's design philosophy (verified record)

- **Deliberate genre ignorance:** avoided playing roguelikes/deckbuilders during development — "I wanted to make mistakes, I wanted to reinvent the wheel" (Timeline post). Only bought Slay the Spire 18 months in, to study controller support. **[HIGH]**
- **Balance by feel:** "If the picture FEELS level but actually isn't, that is better than it being technically level but feeling askew" (Rogueliker interview). **[HIGH]**
- **Anti-gambling, in his will:** "I hate the thought of Balatro becoming a true gambling game so much that when I recently created my will I stipulated that the Balatro IP may never be sold or licensed to any gambling company/Casino" (Aug 2024, widely covered). Balatro borrows casino *aesthetics* while refusing casino *economics* — no MTX, no ads, premium price, free updates. **[HIGH]**
- **Anti-crunch, anti-deadline:** "I love getting sucked into rabbit holes and I don't like trying to force things creatively"; 1.1 delayed because he returned to hobbyist hours after burnout; "the Balatro *player* in me will absolutely not allow me to walk away" ("I'm Slow," Sept 2025). **[HIGH]**
- **Epistemic humility:** blog intro ("LocalThoughts") frames everything as "what happened and how," not "how you should do it," explicitly citing survivorship bias. **[HIGH]**
- **On the 'demon' compulsion-loop framing:** ⚠️ **could not verify.** I searched localthunk's blog (all six posts as of June 2026: LocalThoughts, Solitaire, The Balatro Timeline, Playing Cards, I'm Slow, Bad Grades) and news/interview coverage; no post or interview using "demon" language surfaced. The compulsion-design discussion in the public record lives in interviews (TouchArcade, Rogueliker, Rolling Stone, Game Maker's Notebook podcast) and the anti-gambling statements above. Treat the "demon" reference as unconfirmed folklore unless someone produces the primary source. **[LOW — flagged as not found]**
- **No meta-progression power** is observable design fact; I found no single manifesto post articulating it, so attribute the *stance* to the game, not a quote. **[MED]**

---

## 7. Top 10 directives for Addendum (opinionated)

1. **Build the six juice primitives first** (T/VT ease, juice_up, jiggle accumulator, tilt+shadow, DynaText, event queue with ease-tweens) before any ad-sim logic. They are the product.
2. **Adopt the blocking-queue pattern for *ceremonies* and a non-blocking layer for the live sim.** Two queues, exactly like base vs other.
3. **Pick the multiplication first:** define Addendum's chips×mult equivalent (e.g., hook × convert) before designing a single card.
4. **Interest-style banking** as the economy's skill-check; cap it visibly.
5. **Manufacture the payout reveal** — never stream the score; open envelopes at close-outs.
6. **Pixel-or-stylized assets + a unifying full-screen shader pass** (CRT or print/halftone "ad-trade-rag" equivalent) to glue cheap art into one object.
7. **Audio on day one:** rising-pitch ticks, state-crossfaded stems, defeat pitch-drop. Hire one composer for stems in an odd meter; it's the cheapest identity money buys.
8. **Lua is validated** — LÖVE 11.5 shipped Balatro on every platform including iOS/Android via a fork, but note the port needed a custom runtime + specialist; budget for that or evaluate Defold/Solar2D for first-party mobile rails in the stack track.
9. **Portrait-first, thumb-first, pause-as-verb** — directly attack the mobile port's known weaknesses.
10. **No meta-progression power; unlocks broaden the card pool only.** And take localthunk's pledge: casino energy, never casino economics — especially for a game teaching ad psychology.

---

## Sources

**Primary / official**
- localthunk blog index — https://localthunk.com/blog
- The Balatro Timeline — https://localthunk.com/blog/balatro-timeline-3aarh
- I'm Slow (1.1 delay, anti-crunch) — https://localthunk.com/blog/im-slow
- Bad Grades (Feb 2026, "still working on 1.1") — https://localthunk.com/blog/bad-grades
- LocalThoughts (blog intro) — https://localthunk.com/blog/localthoughts
- localthunk will/gambling tweet — https://x.com/LocalThunk/status/1820752209765961746
- LÖVE releases (11.5 latest stable; checked via GitHub API June 2026) — https://github.com/love2d/love/releases ; 12.0 status — https://love2d.org/forums/viewtopic.php?t=96418

**Code / architecture analyses**
- Balatro source structure deep-dive pt.1 — https://tulip4attoo.github.io/balatro-p1/ ; pt.2 (god functions, globals) — https://tulip4attoo.github.io/balatro-p2/
- Event system reference (WilsontheWolf gist) — https://gist.github.com/WilsontheWolf/87475e6ac25857d8a7c73d3cf81f972a
- Decompiled source mirror (engine/, functions/) — https://github.com/GladdonT/balatro-source-code
- Runtime introspection of Balatro (LÖVE 11.5, main loop) — https://debug.blog/lurk-balatro/
- "Load-bearing Tomato" (defense of card.lua) — https://chhopsky.substack.com/p/premature-optimization-and-rapid
- GameFromScratch on extracting the source — https://gamefromscratch.com/balatro-made-with-love-love2d-that-is/
- HN thread (shaders to reduce assets; mobile haptics) — https://news.ycombinator.com/item?id=42562710
- Steamodded vanilla class map — https://github.com/Steamodded/smods/blob/c35acd87/lsp_def/vanilla.lua
- lovely-injector (Rust TOML patcher) — https://github.com/ethangreen-dev/lovely-injector ; Balatro+ LOVE fork details — https://github.com/ethangreen-dev/lovely-injector/issues/86
- Steamodded — https://github.com/Steamodded/smods

**Game data / math**
- Blinds & antes (targets, multipliers, rewards) — https://balatrowiki.org/w/Blinds_and_Antes
- Endless-ante formula — https://balatrowiki.org/w/Module:Blind_Score
- Scaling guide (+chips < +mult < ×mult) — https://balatrowiki.org/w/Guide:_Scaling
- Economy/interest — https://balatrowiki.org/w/Money
- Tags (all 24) — https://balatrowiki.org/w/Tags
- Polychrome shader behavior — https://balatrowiki.org/w/Polychrome
- Music (5 stems, 7/4, 70% speed, LouisF) — https://balatrowiki.org/w/Music

**Mobile / reception / status**
- Engadget mobile review — https://www.engadget.com/gaming/balatro-is-an-almost-perfect-mobile-port-163050971.html
- 148Apps review (finger-as-cursor) — https://www.148apps.com/balatro/review/
- TAGN (landscape-only complaint context) — https://tagn.wordpress.com/2024/12/20/balatro-on-the-ipad-is-perfection/
- TouchArcade localthunk interview — https://toucharcade.com/2024/03/18/balatro-interview-mobile-port-localthunk-dlc-plans-updates-new-jokers-demo-feedback/
- Rogueliker interview (balance-by-feel quote) — https://rogueliker.com/balatro-interview/
- 5M copies (Jan 2025) — https://www.gamedeveloper.com/business/balatro-sells-5-million-copies-after-end-of-year-spike
- 1.1 delayed to 2026 — https://www.pcgamer.com/games/card-games/balatros-big-1-1-update-is-delayed-to-2026-for-a-very-good-reason-im-slow/
- Anti-gambling will coverage — https://www.gamedeveloper.com/business/balatro-creator-says-he-will-never-let-it-be-licensed-for-gambling-even-after-death
- Juice recreation reference (web, not ground truth) — https://blakecrosley.com/guides/design/balatro ; https://www.wavebeem.com/toybox/2025/balatro/
- Balatro-style background shader for LÖVE — https://gist.github.com/mar1lusk1/4677e482375bff4a01956107aef35699
