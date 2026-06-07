# Spec — buttons-verbs (v0.1 assessment)

> Group: `.btn` family · the verb dock (`.verb` ×5) · `.optoken` (→ **Action Points**) ·
> **End Day** (missing from the library — exists only in `design/mockups/skeleton.html`).
> Law: `design/design-rules.md`. Loop: `design/flows.md` (turn-based days + AP).
> Library source: `design/design-language.html` §"Buttons, Verbs & Tokens" (lines 143–163, 372–391).

**Group verdict: REFINE.** The chunky-press language (shelf shadow, 2px travel, Baloo labels)
is correct and locked. But the section still describes the dead live-flight loop ("op tokens",
"flight phase"), the single most important button in the game (End Day) isn't in the library,
and there are concrete CSS bugs + touch-size shortfalls.

---

## 0. Bugs in the library (fix verbatim)

| # | Where | Bug | Fix |
|---|---|---|---|
| B1 | `.btn:active` (line 149) | hardcodes `box-shadow:0 1px 0 #2c4170` — **danger and secondary buttons press onto a BLUE shelf** | per-variant pressed shelf: danger `#99313f`, sec `var(--line2)` |
| B2 | `.btn.disabled` | `:active` transform still applies — disabled buttons travel | `.btn.disabled:active{transform:none;box-shadow:0 3px 0 #aeb6c8}` (rules §6: disabled is visible + chunky, but it must not *feel* alive) |
| B3 | `.optoken.spent` (line 163) | first declaration `#d4daе6` contains a **Cyrillic е** (U+0435); a duplicate declaration papers over it | delete the dead declaration |
| B4 | `.btn` radius `13px`, `.btn.sec` border `2px` | off-token (radius/chunky = 14, border/component = 2.5) | radius 14px; sec border 2.5px |
| B5 | Section caption | "the verb dock — **flight phase**"; "tokens are the scarce attention"; cap caption "no tokens left" | re-caption for the day loop: verbs are MORNING actions; AP is the day-scoped attention; "no AP left" |

---

## 1. `.btn` — primary / secondary / danger / disabled

**Cites:** generic commit affordance (Launch → sim/composer.lua+wave.lua; Sign → run start; Fire → sim/team.lua).

### Criteria
| Axis | Score | Notes |
|---|---|---|
| Minimal | ✓ | flat fill, one shelf, label only — nothing to remove |
| Effective | △ | height ≈ 44px (11px pad ×2 + 15px/1.5 line) — **below the 48dp floor** (rules §4 `touch/min`); B1/B2 press bugs lie about state |
| Cute | ✓ | Baloo 700 label, hard shelf, real travel — the Duolingo press done right |
| Beautiful | ✓ (after B4) | token-compliant once radius/border land on 14/2.5 |

**Fix:** `padding:13px 22px` (or `min-height:48px`). Danger buttons additionally get
≥16dp clearance from any neighbor (mobileux §1.2) — a layout rule, note it in the cell caption.

### States (full set — rules §6 "Interactive elements")
| State | Treatment | Present in v0.1? |
|---|---|---|
| default | fill + `0 3px 0` darker-of-fill shelf | ✓ |
| pressed | `translateY(2px)`, shelf → `0 1px 0` same hue | ✓ base / ✗ variants (B1) |
| disabled | `#c9cfdd` on `#aeb6c8`, **no travel**, label kept | ✓ fill / ✗ travel (B2) |
| confirm (danger only) | second tap required: label swaps to the price (`Sure? −$60 severance`), amber sub-text, 3s revert | ✗ — add. Fire/severance is irreversible; turn-based pace means a 2-tap confirm costs nothing and hold-to-confirm is unnecessary |

No loading/spinner state — turn-based commits are instant by design. No focus state (touch-only).

### Animation
| Trigger | Motion | Spec | Haptic |
|---|---|---|---|
| touch-down | press | **pressy** 60ms | Whisper (transient i 0.4 s 0.6 / `LOW_TICK` 0.5) |
| release-commit | release | pressy 60ms | none — the **consequence component** owns the ceremony (ad seats, pack rips, Maya's card sags); the button never animates anything but itself (rule 3) |

### Overlap
- `.btn.sec` is the same recipe as `.verb` and `.dchip` (white tile, line2 border, line2 shelf,
  Baloo label, pressy). **Extract one atom — `pressable`** (fill, border, shelf-color, label) —
  and derive all three. One Lua/GUI template, three parameter sets.
- The "Inspect" example duplicates the universal **tap-to-inspect** gesture (tap is always safe,
  mobileux §1.3). Keep `.btn.sec` the class; re-example it with an action that is actually a
  button (`Not Now`, `View Codex`).

### Variants
**No size variants.** One size, width-flexible. The hero-commit need is covered by End Day
(its own component, §4) — do not grow a "large primary".

---

## 2. The verb dock — Kill / Boost / Swap / Call It / Diagnose

**Cites (corrected):** sim/wave.lua (verbs act on live ads) · **day loop AP budget** (flows.md) ·
sim/significance.lua (Call It) · sim/diagnosis.lua (Diagnose). KILL free always — celebrated.

Post-pivot anchor: the dock is a **MORNING** surface — contextual to the selected live ad,
spending from the day's AP. Nothing about it may imply mid-flight timing (rule 8).

### Criteria
| Axis | Score | Notes |
|---|---|---|
| Minimal | ✓ | name + cost, nothing else |
| Effective | △ | ~62px tall ✓ (≥56dp); but cost glyph `◆ 1` is a **text glyph** (icon ruling §3 bans loose glyphs) and not the AP atom; Kill sits 8px from Boost — destructive needs **≥16dp** clearance; no unaffordable/armed states |
| Cute | ✓ | tile + shelf + Baloo verb — good |
| Beautiful | △ | cost line needs the real AP pip; FREE-in-green is correct (green owns FREE, rules §4) |

### States (full set — this is the finding-rich row)
| State | Treatment | Present? |
|---|---|---|
| affordable (default) | white tile, line2 border + shelf; cost line shows mini AP pip ×n, or green FREE | ✓ (glyph wrong) |
| pressed | pressy travel, shelf → `0 1px 0 var(--line2)` (current `none` is legal per rules §4 but standardize on 1px with `.btn`) | ✓ |
| **armed** (awaiting target: Swap → pick card, Boost → confirm lane) | border → `--blue` (the border speaks), tile stays white; tap elsewhere cancels | ✗ — **add** |
| **unaffordable** (AP < cost) | disabled treatment: `#c9cfdd`-grayed label + cost, lighter shelf, no travel; **cost stays legible** (the economy is the curriculum) | ✗ — **add** |
| **not-applicable** (Call It with no race; Boost with no leader) | same disabled treatment. Dock always shows all five — spatial stability over hiding | ✗ — **add** |
| Diagnose cost machine | per **day** (not per flight): cost line `1ST FREE` → after first use `[pip] 1` — state-as-treatment of the cost line only, tile unchanged | ✗ caption says flight — fix |
| Kill identity | label tinted `--red` (red owns kill, rules §4); tile stays white — destructive but celebrated, not scary | ✗ — add |

### Animation
| Trigger | Motion | Spec | Haptic |
|---|---|---|---|
| dock appears (ad selected) | **pop** ~180ms ease-out, dock as one unit | never while anything else is animating | none |
| touch-down | pressy 60ms | | Whisper |
| arm | border color swap inside the same pop, 180ms | | Whisper detent |
| cancel (tap away) | **return** ~250ms spring to default | | none |
| commit | the **target** animates: Kill → ad collapses via return + budget-refund float; Boost → budget bar rolls (count-up); Swap → card swap snap + shimmer restart on the ad's chips | verb tile itself only releases | Voice on the target's landing frame (Kill = the celebrated quick double-tick) |
| AP cost lands | after the commit lands (one thing at a time): rail pip drains, §3 | | Whisper |

### Overlap
- `.dchip` (diagnose guess chips, Knowledge group) = `pressable` atom minus the cost line.
  Share the atom; do not let the two drift.
- `skeleton.html`'s hover-reveal `killx` (red ⨉ on ad cards) duplicates Kill and **depends on
  hover, which doesn't exist on touch**. The verb dock is the only kill path. Delete the pattern.
- Call It vs the Pin: deliberately distinct acts (pre-data vs early-resolve) — no merge, and
  per docs/01 §2 the names never mix. ✓ as-is.

### Variants
**None.** One dock, one context (Desk, ad selected). Build/Iterate are NOT dock verbs — they
live on the empty-slot card and the ad tile (skeleton already does this correctly).

---

## 3. `.optoken` → **Action Points** (rename everywhere)

**Cites (corrected):** the day loop's AP budget (flows.md; DECISIONS loop pivot — "flight
op-tokens merge into AP"). Display-only resource row; never a touch target.

### Criteria
| Axis | Score | Notes |
|---|---|---|
| Minimal | ✓ | a shape and a state |
| Effective | △ | the concept it renders no longer exists under that name; **two competing implementations** (library `.optoken` 30px vs skeleton `.apdot` 16px) |
| Cute | ✓ | rotated-square pip with its own shelf — distinct from trust pips (green rects) and day dots (circles); three resource shapes, three meanings — keep |
| Beautiful | ✓ (after B3) | blue-on-shelf / gray-on-gray reads instantly |

### States (rules §6 Resources)
| State | Treatment | Present? |
|---|---|---|
| full | `--blue` fill, `0 2px 0 #2c4170` shelf | ✓ |
| spent | `#d4dae6` on line2 shelf | ✓ (typo B3) |
| **earmarked** (a costed verb is armed) | full pip at 50% fill opacity, shelf kept — previews the spend, sits still (no pulse — rule 8 no-anxiety) | ✗ — **add**: the cost must be legible *before* commit (rule 8½ — the interface never lies) |

Row supports **n pips** (base 3, +team capacity — tunable). Count is data, not layout.

### Animation
| Trigger | Motion | Spec | Haptic |
|---|---|---|---|
| spend | one pip drains full→spent, **pop** ~180ms, after the verb's commit lands | one at a time | Whisper tick |
| morning refill | pips refill one-by-one, pop ×n at ~120ms spacing, inside the Morning Report beat | sequenced, never simultaneous | Whisper per pip (≥80ms apart ✓) |
| idle | **nothing** — AP pips sit still until spent (rules §5 law 5) | | |

### Overlap / Variants
- **Merge `.optoken` + skeleton's `.apdot` + the verb-dock cost glyph into ONE atom** ("AP pip"),
  parameterized by size. This is the one justified variant set in the group:
  - **rail** ~20–24px — the Desk's AP row (split the 30/16 difference; tune on device)
  - **cost glyph** ~10–12px — inside `.verb` cost lines, replacing the `◆` text glyph
  - Same shape, same colors, same spent treatment at both sizes — cost is denominated in the
    same pixels as the wallet. No third size.
- Trust pips / flight-day dots: deliberately different shapes — no merge, but implement all
  three on one "pip row" layout helper.

---

## 4. **End Day** — promote into the library (currently missing)

**Cites:** the day loop's commit (flows.md "END DAY (the commit)"); triggers the Night
resolution ceremony (sim ceremony queue). **The most important button in the game** — it is
the Balatro "play hand" lever. It exists only in `mockups/skeleton.html` (`.endday`, amber).
A library that lacks it fails rule 6's spirit: the game's central verb has no component.

### Criteria (scoring the skeleton draft)
| Axis | Score | Notes |
|---|---|---|
| Minimal | ✓ | label + day sub-label |
| Effective | △ | no forfeit-AP telegraph; color contested (below) |
| Cute | ✓ | biggest shelf in the game (4px), 3px travel — heavier button, heavier commitment. Keep |
| Beautiful | ✗ as amber | **color-law conflict**: amber = wear/warning/target (rules §4); a commit button wearing the warning color moonlights. Needs an author ruling |

**Color recommendation:** `--blue`. End Day is the apex of player agency, and blue *is*
"action + knowledge — the player's agency." Differentiate from `.btn` primary by **mass, not
hue**: 16px radius, `0 4px 0 #2c4170` shelf, 3px travel, 17px/800 label, the day sub-label —
no other blue button has any of these. (Runner-up: `--ink` fill — the "serious" fill shared
with boss/canon — if blue-on-blue-rail proves muddy on the Desk. Amber is reserved for this
button's *forfeit state*, where a warning is honest.) Log the ruling in DECISIONS.md.

### Component definition
```
.endday — width ~112–128px (right rail), radius 16px, Baloo 2 800 17px white,
  fill --blue, shelf 0 4px 0 #2c4170, padding ≥18px (≥56dp tall)
  sub-label: Nunito 800 9.5–10px caps, 85% opacity — carries day identity ("MON → market")
```

### States
| State | Treatment |
|---|---|
| ready (0 AP left) | full fill; sub-label = day identity (`MON → market`; Sunday: `SUN → week close`) |
| **forfeit warning** (AP unspent) | sub-label swaps to amber `2 AP UNSPENT` — static, no pulse (rule 8). The honest telegraph that no-carryover forfeits them (flows open Q4) |
| pressed | `translateY(3px)`, shelf → `0 1px 0` — deeper travel than any other button |
| night | absent — the Night overlay replaces the Desk; the button never coexists with its own ceremony |
| tutorial cue (day 1 only) | one-shot pulse, scale 1.0→1.04→1.0 ~600ms, **once** — an event, not a loop |

Never disabled: ending the day is always legal.

### Animation
| Trigger | Motion | Spec | Haptic / SFX |
|---|---|---|---|
| touch-down | press | pressy 60ms, 3px travel | — |
| commit | ~200ms windup (button settles + Desk dims) → Night ceremony begins | **setpiece handoff**: End Day owns only the windup; the ceremony queue owns the night | **the lever pull** — Voice→Shout: continuous 250ms i 0.3→0.9 + transient i 1.0 (mobileux "Ad launch" pattern); riser + thump SFX on the same frame. Once per ~60–90s day — inside the ≤1 Shout/10s budget |

### Overlap / Variants
- **Not a `.btn` variant.** Unique geometry, travel, sub-label, ceremony role — its own
  component, exactly one instance in the game. No variants.
- Placement (right rail vs center-bottom lever) is flows open Q2 — a screen decision; this
  spec constrains only the component.

---

## 5. Group summary

| Component | Verdict | Top fix |
|---|---|---|
| `.btn` family | refine | B1/B2 press bugs; 48dp height; danger confirm state |
| verb dock | refine | re-anchor to day loop; armed + unaffordable states; AP-pip cost glyph; Kill clearance + red label |
| AP pips | refine | rename op tokens → Action Points; one atom, two sizes; earmarked state; B3 typo |
| **End Day** | **add** | promote from skeleton into the library; resolve color vs the color law; forfeit-warning state |

Shared atoms to extract: **`pressable`** (btn.sec / verb / dchip) and **`AP pip`**
(rail / cost-glyph). Both are one-template-many-parameters jobs in Defold GUI.
