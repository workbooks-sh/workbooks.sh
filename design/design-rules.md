# ADDENDUM design rules — v1.1

> Codified 2026-06-05 from the v0.1 component library (`design/design-language.html`) and the
> author rulings in `DECISIONS.md` (design rounds 1–5 + the loop pivot). v1.1 syncs the §5/§6
> state model to the v0.2 library pass (limited/fatigued rename + stage 2 + scars, foil-on-any-
> rarity, the MON–SUN week strip, week-close interest). The component library
> is the source of truth for *what exists*; this doc is the source of truth for *why* and
> *how to extend it*. Screens are assembled FROM the library — never invented per-screen.
>
> The author's brief, verbatim: **"minimal, effective, cute, and beautiful."** Chunky fun.
> Not techie. This is a GAME.

Companion docs: `docs/01-game-design.md` (what each primitive means mechanically),
`docs/research/mobileux.md` (touch targets, haptics, feel-spec numbers), `DECISIONS.md`
(rulings; reversals get new entries there, and then a version bump here).

---

## 1. PRINCIPLES — the eight-and-a-half hard rules

1. **Cards are the UI.**
   Every game object the player touches is a card or a card descendant (chip, tile, pack, pip) — this is the one idea that survived all five design rounds, so a screen with no cards on it is probably a wrong screen.

2. **State is treatment, not chrome.**
   Wear is desaturation, learning is shimmer, spent is gray — a state change re-renders the pixels a component already has; it never adds a badge, banner, overlay icon, or extra label.

3. **One thing animates at a time.**
   The settle pass is the master pattern: End Day resolves as a blocking ceremony queue that reveals one update, lets it land, then reveals the next — never stream the score, never animate two payoffs simultaneously.

4. **Chunky means physical: every interactive element has a pressed state with a real drop.**
   Buttons, verbs, and chips sit on a hard shelf shadow (`0 3px 0 <darker>`) and press *down into it* (`translateY(2px)`, shelf collapses) — if it can be tapped, it can be felt moving, in ~60ms.

5. **Real metric names, always.**
   ROAS, CTR, CVR, HOOK, HOLD, `CREATIVE LIMITED`, `CREATIVE FATIGUE` (Meta's literal words) — the vocabulary is the curriculum, so the UI never invents a cuter synonym for a real metric.

6. **Nothing is decoration.**
   Every component cites the sim module it renders (see the captions in `design-language.html`); if a proposed element doesn't render a real sim primitive, it doesn't ship.

7. **Light mode, paper room, friendly.**
   White cards on the FB gray-blue paper (`#eef1f6`), deep navy ink, retro-FB blue — explicitly "not techie dark mode shit"; if a mock reads like a SaaS dashboard or a crypto terminal, it has failed.

8. **Day-ceremony pace, not stream pace.**
   The loop is turn-based days with Action Points — components read at End-Day resolution (a planned act, then a sequenced payout), so nothing in the UI implies live pressure: no ticking clocks, no draining real-time meters, no anxious pulses.

8½. **The interface never lies.**
   The race needle wobbles honestly, the bell rings only at real significance, pack odds are printed, the projection chain's arithmetic actually computes — juice amplifies the truth, it never fakes one.

---

## 2. EMULATION TARGETS — what we take, what we refuse

### Retro Facebook (~2007–2010)
- **Take:** THE blue (`#3b5998`), the gray-blue paper room, white surfaces with thin cool-gray hairlines, friendly small-caps labels, pill-shaped tags, the feeling that software can be a cozy place.
- **Do NOT take:** feed density, infinite scroll, notification-red engagement bait, tiny 11px link soup, any actual 2008 chrome (gradients-on-gradients, beveled toolbars).

### Balatro
- **Take:** ceremony sequencing — score events resolve one at a time with weight; the pack-rip as a ritual; foil/shine reserved for genuinely rare objects; interest-with-a-visible-cap legibility; audio pitch-ramping juice on count-ups; landscape table layout.
- **Do NOT take:** the CRT/pixel/phosphor aesthetic (explicitly killed in rounds 1–3: "too crypto pixelated"), the dark felt palette, psychedelic background shaders, or its UI density — Balatro tolerates clutter we can't.

### Marvel Snap
- **Take:** number-on-card restraint — one big power number per ad tile (revenue), everything else is meta; drag lifts the card above the finger; haptics that scale from whisper-tap to shout-boom and are therefore *felt* as meaning; max 3–4 KPIs at rest.
- **Do NOT take:** dark sci-fi gloss, layered premium VFX on every play, monetization patterns, season-pass chrome.

### Duolingo / Two Dots-class chunky-cute mobile
- **Take:** the 3D pressed button (hard shelf shadow, travels down on tap), big rounded display type (Baloo 2 is our Feather Bold), generous tap targets (≥48dp, ≥56dp for in-play verbs), color that is saturated but never neon, cheerful disabled states.
- **Do NOT take:** streak guilt, push-notification nagging, lives/energy timers, mascot histrionics — cute is a texture here, not a retention mechanic.

### Meta Ads Manager (the real thing)
- **Take:** the *vocabulary only* — metric names, funnel gate order (impressions → hook → hold → CTR → CVR), the literal fatigue status strings, the campaign/ad-set/ad hierarchy (client → lane → ad).
- **Do NOT take:** literally anything visual. Tables, toolbars, filters, blue links — all banned. We render its *concepts* as cards.

---

## 3. ICON & EMOJI STRATEGY

### The cross-platform reality (researched 2026-06)

- **Apple's emoji set cannot ship in this game.** It is copyrighted, unlicensed, and App Store
  Review Guideline 5.2.5 explicitly forbids apps embedding Apple emoji as assets
  ([Emojipedia licensing](https://emojipedia.org/licensing),
  [emoji licensing guide](https://github.com/luizbizzio/emojis)). On Android the system set is
  Google's Noto; Samsung overrides it again. Emoji-as-text = three different games.
- **Defold makes the decision for us anyway:** its font pipeline rasterizes monochrome
  bitmap/SDF glyphs ([font manual](https://defold.com/manuals/font/)) — there is no color-emoji
  font path. Any emoji we show is, by necessity, **an image in an atlas**
  ([atlas manual](https://defold.com/manuals/atlas/)). So we control the pixels — which means we
  pick one set and it looks identical on every device.
- **Shippable emoji image sets:**
  - **Noto Emoji** — Apache 2.0, official PNG + SVG assets, no attribution clutter, no
    share-alike ([googlefonts/noto-emoji](https://github.com/googlefonts/noto-emoji)). ✅
  - **Twemoji (jdecked fork)** — CC BY 4.0, actively maintained (Discord uses it), requires
    attribution ([jdecked/twemoji](https://github.com/jdecked/twemoji)). Acceptable fallback.
  - **OpenMoji** — CC BY-SA 4.0: share-alike contaminates modified art in a commercial game.
    ❌ Avoid.

### Icon library evaluation (UI chrome)

| Library | License | Weights/fill | Fit for chunky-cute light UI |
|---|---|---|---|
| **Phosphor** | MIT | 6 hand-drawn weights: Thin → Bold, **Fill**, Duotone | **Best fit** — drawn "friendly and organic" rather than strictly geometric; Fill weight reads chunky at chip size; MIT is clean for a commercial game ([phosphoricons.com](https://phosphoricons.com)) |
| Lucide | ISC | one outline style, math-scaled stroke | Clean license but geometric/techie — reads SaaS, fails rule 7 ([lucide.dev/license](https://lucide.dev/license)) |
| Iconoir | MIT | thin single stroke | Too wispy for chunky; fails at 16–20px in chips |
| Streamline | Free tier needs visible attribution; full sets paid | huge variety | License friction for zero aesthetic win ([Streamline free license](https://help.streamlinehq.com/en/articles/5354376-streamline-free-license)) |

### THE RULING

1. **UI chrome uses Phosphor, Fill weight, exclusively.** Every glyph in chips, buttons, verbs,
   toasts, codex rows, note rows, stat labels (the `★ ⚗ 👁 📌 ⚡ 📬 ✦ ？ 😴 🤷 ⚪ 📈` set
   shipped in the v0.1 library — migrated in v0.2) gets replaced by a Phosphor Fill icon
   tinted with a token color.
   Bold (outline) weight is permitted only where a fill shape is illegible (e.g., an
   "empty slot" glyph) — and never mixed with Fill inside one component.
2. **Emoji are card-art placeholders only — never chrome.** The `.art`, `.minislot`, `.face`,
   and `.pack .em` emojis are stand-ins for commissioned card illustrations. They may live
   through prototyping and playtest builds. If any survive to ship (e.g., as a deliberate
   placeholder style for v1 card art), they ship as **Noto Emoji PNG textures** in our atlas —
   one set, identical on iOS and Android, Apache 2.0.
3. **The consistency rule:** one icon set (Phosphor), one weight per context (Fill), one emoji
   set (Noto, art-side only), and **icons and emoji never appear on the same surface** — a card's
   art well may be emoji-placeholder; the chips and buttons around it are icons. No exceptions,
   no "just this once" glyph from another set.

### SVG → Defold pipeline

- Curate the actual icon list (expect ~30–50 icons total — rule 6 keeps this small).
- Build script rasterizes Phosphor SVGs to **white** PNGs at @1x/@2x (e.g., 48px/96px) via
  `rsvg-convert` (or Inkscape CLI), output into `assets/icons/` → packed into `icons.atlas`.
- Icons are authored white and **tinted at runtime** via GUI node color with token colors —
  one texture serves every semantic color, and recoloring a state costs zero new assets.
- Rejected alternative: mounting Phosphor's TTF as a Defold font (codepoint management pain,
  monochrome anyway, no per-icon control). Atlas PNGs are the standard Defold practice.
- Noto Emoji ships official PNGs — same atlas treatment, but at full color (no tinting).

---

## 4. COLOR + TYPE + SPACING TOKENS

### Color tokens — every color has a mechanical meaning

A color never moonlights. Green never decorates a non-money thing; red never appears where
nothing is being lost. If you need a color and its meaning doesn't match, you need a different
design, not a new color.

| Token | Value | Means (mechanically) | Used by |
|---|---|---|---|
| `--paper` | `#eef1f6` | the room — neutral world background | body, bar troughs, gate troughs |
| `--card` | `#ffffff` | a surface that holds a sim object | cards, tiles, plates, notes, hires |
| `--line` | `#d8deea` | hairline structure | section rules, light borders |
| `--line2` | `#c4ccdc` | component edges + resting shelves | card borders, verb borders, shelf shadows |
| `--ink` | `#1c2b4a` | text; also the boss/canon "serious" fill | all body text, `c-boss`, `cx-canon` |
| `--dim` | `#7c8aa5` | meta information, labels, costs | kickers, captions, LABELS |
| `--blue` | `#3b5998` | **action + knowledge** — the player's agency | primary buttons, score plate, day-live, learning, observed, pins, op tokens |
| `--blue2` | `#5872b8` | secondary blue — progress, uncommon | track fills, day-done, uncommon border |
| `--bluepale` | `#e9eef9` | blue's tint field | learning chips, pins, faces, rule pills |
| `--green` | `#3fa15f` | **money** — revenue, bankroll, FREE | power numbers, bank, pips, leader, FREE costs |
| `--greenpale` | `#e4f4e9` | green's tint field | leader chips, social tags, offer art well |
| `--amber` | `#d98e04` | **wear + warning + target** — attention, not danger | Creative Limited, brief tick, the leak stat, bell line, telegraphs, claimed confidence |
| `--amberpale` | `#fdf3dd` | amber's tint field | warn chips, IP pill, conf pill |
| `--red` | `#d0455a` | **fatigue + danger + cost-of-people** | Creative Fatigue, danger buttons, salary, urgency tags, kill |
| `--redpale` | `#fbe9ec` | red's tint field | fatigue chips, urgency tags |
| `--gold` | `#b58a2c` | **rarity + minted value** | rare borders, V2 flag, canon star (`#ffd76b` on ink) |

**Derived/fixed values** (not freely reusable): pressed shelves — blue `#2c4170`, red `#99313f`,
green `#2e7847`, gold `#9a7424`; disabled fill `#c9cfdd` on shelf `#aeb6c8`; spent gray
`#ececf1`/`#9a9aa8`; card-kind art tints — hook `#fdebe2`, visual `#e3f1fd`, format `#eee9fb`,
offer `#e4f4e9`, modifier `#fdf3dd` (same hue family as the tag colors: kind and aspect rhyme;
the modifier tint rhymes with the IP pill — "attaches to" value-in-waiting).

**Accessibility rule (from mobileux §3.3):** meaning is never color-alone — every red/green
distinction also differs by icon shape, position, or motion pattern; CVD-simulator pass is a
release gate.

### Type tokens

| Token | Face | Size/weight | Usage |
|---|---|---|---|
| `type/score` | Baloo 2 800 | 52px | the score plate hero number |
| `type/display` | Baloo 2 800 | 34px | screen titles, run-end ceremony |
| `type/big-num` | Baloo 2 800 | 20–24px | power numbers, bank, stats, floats |
| `type/heading` | Baloo 2 700 | 21px | section heads |
| `type/card-name` | Baloo 2 700 | 14.5–16px | card names, tile names, button labels, verbs |
| `type/body` | Nunito 600 | 13–14px | sentences: bubbles, notes, toasts |
| `type/meta` | Nunito 700 | 11–12px | lanes, roles, evidence counts |
| `type/label` | Nunito 800 CAPS | 10–11px, +0.6–1.2px tracking | metric labels, kickers, costs |

Rules: **Baloo 2 owns numbers and names; Nunito owns sentences and labels.** All numbers are
tabular (`font-variant-numeric: tabular-nums`) so count-ups never jitter. No third typeface,
no italic display, no thin weights — nothing below Nunito 600 exists.

### Shape, shadow, spacing

| Token | Value | Rule |
|---|---|---|
| `radius/chunky` | 14px (`--r`) | default for every surface |
| `radius/card` | 16px | component cards + packs |
| `radius/inner` | 7–10px | nested elements (art wells, minislots, pips, gbars) |
| `radius/pill` | 99px | chips, tags, prices — anything that names a state |
| `border/component` | 2.5px `--line2` | cards, verbs, diag chips (rarity recolors it — "the border speaks") |
| `border/hairline` | 2px `--line` | quiet surfaces |
| `shadow/rest` | `0 2px 0 --line2, 0 6px 16px rgba(28,43,74,.07)` | every resting surface: a hard 2px shelf + a soft ambient — paper sitting on paper |
| `shadow/press-shelf` | `0 3px 0 <darker-of-fill>` | interactive elements; collapses to `0 1px 0`/none when pressed |
| `space/1..5` | 4 / 8 / 12 / 16 / 24px | 4px base grid; 24 between cells, 12–16 inside components, 4–8 between tags/pips |
| `touch/min` | 48dp | every tappable; **56dp** for in-play verbs; ≥16dp clearance around destructive actions |

---

## 5. MOTION PRINCIPLES

### The settle pass is the master pattern

End Day triggers the **resolution ceremony**: a blocking reveal queue (sim's ceremony queue made
visual). Each item — per-ad revenue float, bankroll count-up, fatigue chip advance, race
needle move or BELL, the week-strip day handoff — plays alone, lands, *then* the next begins.
Interest is **not** a nightly item: it pays as the FIRST beat of the week-close ceremony
($1 per $5 banked, cap $100 — computed, never authored).
Tap-to-advance is allowed; tap-to-skip-all is allowed after the first reveal; simultaneity never
is. The bell freeze-frame and the pack rip are the same pattern at higher amplitude.

### Duration & easing vocabulary

| Name | Spec | Used for |
|---|---|---|
| **pressy** | 60ms, linear-ish | button/verb/chip press-down and release |
| **snap** | ≤120ms, slight overshoot | card seating into a slot |
| **pop** | ~180ms, ease-out, scale to 1.1–1.15× | tap-to-inspect lift, chip state change |
| **return** | ~250ms spring | snap-back to hand, panel dismiss |
| **count-up** | 300–800ms ease-out — longer = bigger win | every number change; digits roll, never teleport |
| **float** | ~700ms rise + fade | the settle float (`+$45`) |
| **setpiece** | 700–1100ms choreography | bell freeze-frame, pack rip, wave grade |
| **shimmer** | 1.6s linear loop | learning-phase metrics (state, not event) |
| **foil** | 3.2s ease-in-out loop | legendary/V2 shine sweep (state, not event) |

### Laws

1. **One thing at a time** (rule 3). Ambient state loops (shimmer, foil) are exempt — they're
   treatment, not events — but cap visible loops at ~2 per screen; three shimmering things is
   a design bug.
2. **Numbers roll, 2–4 ticks/s max.** Sim updates batch into discrete visible ticks; a counter
   updating 60×/s reads as noise, one ticking 2–4×/s reads as alive.
3. **Every Shout-class animation has a haptic** — one animation keyframe + one transient SFX +
   one haptic fired on the same frame (visual may lead by ≤1 frame, never the haptic).
   Classes per mobileux §2: **Whisper** (pickup, hover detent, metric ticks — ≥80–100ms apart),
   **Voice** (snap, chip state change, fatigue double-knock, day close), **Shout** (bell,
   pack rip, wave grade, FIRED — ≤1 per ~10s, or it stops being a jackpot).
4. **120Hz only while a finger is dragging** and during Shout setpieces; settle to 60, idle at
   30. Battery is a feel feature in a 30-minute session.
5. **No anxiety motion.** Turn-based days mean nothing pulses to rush the player: AP pips sit
   still until spent, fatigue advances only at the ceremony, timers don't exist.

---

## 6. STATE MODEL

The canonical states the game manages, and how each renders. The law: **a state change is a
re-treatment of existing pixels — filter, opacity, border color, fill, or an ambient loop —
never added chrome.** The one sanctioned "extra element" is the status chip vocabulary, because
chips are themselves sim objects (Meta's literal fatigue words), not decoration.

### Interactive elements (buttons, verbs, diag chips)
| State | Treatment |
|---|---|
| default | rest on `shadow/press-shelf` |
| pressed | `translateY(2px)`, shelf collapses (pressy, 60ms) |
| disabled | desaturated fill `#c9cfdd` + lighter shelf — still visible, still chunky, never hidden, and it **never travels** on press |

### Component cards (sim/fatigue.lua lifecycle)
| State | Treatment |
|---|---|
| fresh | full color |
| limited (`CREATIVE LIMITED`) | `saturate(.55)`, art at 65% opacity |
| fatigued (`CREATIVE FATIGUE`) | `saturate(.35)`, art at 50% opacity |
| spent (3 scars → retires) | `saturate(.2)`, 75% opacity; retires into Learnings |

Scars (0–3) are permanent and global: one dog-eared corner per completed wear cycle
(top-left → top-right → bottom-left) — countable, never a badge.

### Rarity (sim/economy.lua) — "the border speaks"
common = `--line2` border · uncommon = `--blue2` · rare = `--gold` + gold-tinted shadow ·
legendary = rainbow gradient border. **Foil V2 is an independent identity axis**, stackable
on ANY rarity (economy.lua mints a V2 from any fatigued winner + IP): the 3.2s shine sweep
(art well only) + the gold V2 flag, border stays whatever rarity says. Ambient foil caps at
2/screen; excess renders frozen shine (parked at 47%).

### Metrics (sim/shimmer.lua, sim/significance.lua)
| State | Treatment |
|---|---|
| learning | shimmer sweep across the chip/number until ~10 conversions |
| calibrated | shimmer stops; number sits steady |
| racing | needle wobbles honestly on the track |
| significant | freeze-frame + BELL setpiece — the only moment the race is allowed to shout |

### Ads in flight (sim/wave.lua)
live · **leader** (pale-green outline + Leader chip) · limited (amber chip) · fatigued
(red chip) · spent (gray chip) · killed (collapses out via *return*, budget visibly refunds).

### Knowledge (sim/ledger.lua)
| State | Treatment |
|---|---|
| unseen | spent-gray pill, placeholder glyph |
| observed | `--bluepale`/`--blue` pill, 1-run evidence count |
| canon | ink fill + gold star — replicated across 2 runs; the only ink-filled pill besides boss |

### Resources
AP pips (Action Points): full color on shelf → spent = gray on gray shelf; earmarked
(an armed costed verb) = 50% fill opacity, shelf kept, no pulse. Trust pips: green → spent gray.
Week strip (MON–SUN cells, replaces flight-day dots): upcoming (paper/dim) → done (`--blue2`,
no strike-through) → live (`--blue` + press shelf, no ring) → telegraphed (`--amberpale`/`--amber`
— tomorrow's weather from the director).

### People (sim/strategist.lua)
Claimed confidence renders in **amber** (a warning, mechanically) against the **blue** track
record bar she actually runs — the gap between the two IS the character.

---

*Change control: aesthetic reversals land in `DECISIONS.md` first, then bump this doc.
If a mock and this doc disagree, the most recent author ruling wins; if rulings and the
component library disagree, fix the library — never fork the language inside a screen.*
