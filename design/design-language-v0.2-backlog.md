# Design language v0.2 backlog

> Single prioritized backlog distilled from the nine spec assessments (`design/specs/*.md`)
> against `design/design-language.html` v0.1 and `design/design-rules.md` v1.0.
> Ordered by **player-facing impact × cheapness**. Two buckets: **A** = do in the next
> library pass (HTML library + rules doc); **B** = do when the component first appears on
> a real screen (motion, haptics, ceremony sequencing, on-device checks).

## 0. CONTRADICTIONS BETWEEN SPECS — resolve before the pass (rulings → DECISIONS.md)

1. **Shimmer overflow (>2 learning chips).** composed-ad F10: all Learning chips share **one
   synchronized phase** (in-unison = one ambient system). status-chips: **serialize round-robin**,
   one sweep in motion, ~0.8s gap. Same atom, opposite mechanisms. Recommend synchronized phase
   (cheaper, calmer, no implied ordering between equal states) — but it needs one author ruling.
2. **Small-chip token has three names.** composed-ad mints `chip--sm`; status-chips tokenizes
   "badge" (10px / 2px 8px); knowledge mints `chip--mini` (same values). One token, defined in
   the chips group (the owner), one name; update all consumers (adtile Leader, note flask, pin stamps).
3. **`.pricetag` fate.** component-card: "survives for upgrades only." events-shop: **dissolved
   entirely** — upgrades get a dedicated upgrade tile + unified price atom. events-shop is the
   owning group and more complete; recommend dissolve, then amend component-card §pricetag line.
4. **Spend-token ownership.** buttons-verbs defines ONE AP-pip atom (two sizes + earmarked);
   resources defines a parameterized spend-token atom covering trust pips AND AP. Compatible but
   double-claimed: define resources' generalization once, AP-pip = its parameter set.
5. **Fill+tick bar double-claimed.** score-metrics' shared meter atom (FunnelStat block/gate) and
   people's `.bar`/`.tbar` merge are the same primitive. Build once; consumers: score plate, funnel
   gates, hire track record.

## A. NEXT LIBRARY PASS (impact × cheapness order)

### A1 — Bug & law fixes (hours, zero design risk)
1. Buttons CSS: `.btn:active` hardcodes blue shelf `#2c4170` (l.149 — danger/secondary press wrong);
   `.btn.disabled` still travels on `:active`; Cyrillic 'е' typo in `#d4daе6` (l.163); radius 13→14px;
   `.sec` border 2→2.5px; `min-height:48px` (currently ~44px, below touch floor).
2. Color law: calibration claimed-tick red→amber (design-language.html:226); End Day amber→**blue**
   (blue = agency); race meter — delete red B-side (nothing is lost); Kill label red-tinted + ≥16dp from Boost.
3. Loop-pivot copy sweep: "day 3" → weekday identity ("live MON"); kill the "12s" countdown copy;
   "op token" → Action Points; "salary / wave" → "salary / week"; verb-dock caption flight→day
   ("Diagnose: 1st free per DAY"); day-close stinger "Day 3" → weekday.
4. Honesty (rule 8½): bankroll interest **computed** ($1 per $5, cap $100) + at-cap text state;
   publish meter scales (score bar 0→1.25×target, tick at 80%; gates 0→2×forecast, hairline 50%;
   needle x = 50% + 42%×clamp(z/z_bell)); pack face prints "3 CARDS · 70/25/5" + inspect-before-buy;
   owned-duplicate "→ ✦2 IP" pre-purchase state; Pin copy "Call it: A wins" → "PINNED — A wins HOOK".

### A2 — Icon/emoji migration (concrete tasks; Phosphor Fill, token-tinted, per the ruling)
5. Status chips: replace 7px dot, ★, ⚗ with one Phosphor Fill icon per state (12px, currentColor).
6. Score/metrics: 🔔 → Bell, 📌 → PushPin; leak-warn gains the Drop glyph (shape redundancy).
7. Resources: 💰 → Coins tinted `--green`; ✦ → Sparkle tinted `--amber`.
8. Knowledge (worst offender): all 8 glyphs (trend/circle/flask/question/eye/star/sleep/shrug) → Phosphor Fill.
9. Events/shop: ⚡📬🔥⬆️ → Phosphor Fill; author the 5-kind director icon+copy table
   (cpm_spike / cpm_dip / competitor_entry / viral_moment / metrics_blackout).
10. Composed ad: empty-slot "+" → Phosphor **Bold** (the one sanctioned outline case).
11. While sweeping: curate the full icon list (~30–50) for the atlas build (pipeline itself is B).

### A3 — Missing primitives & states (library-renderable)
12. MODIFIER kind: derived art tint + exemplar card (attached charm-pip micro-form) + tinted minislot —
    the 5th kind (~24 of ~150 v1 cards) is currently invisible.
13. Card lifecycle: stage-2 CREATIVE FATIGUE treatment; scars 0–3 as countable dog-eared corners;
    rename `.worn` → `.limited` (+ rules §6).
14. Foil = identity axis stackable on ANY rarity (economy.lua mints V2 from any fatigued winner + IP):
    fix exemplar + the conflated rules §6 line; cap ambient foil at 2/screen with frozen-shine.
15. Card back (pack flips, fanned hand); shop single = real ccard + price pill (per §0.3 ruling).
16. Played-ad Desk card ported from table-screen.html into the light language (white card, Baloo 2
    name, green power number, minislot recipe strip); kill idle wobble; states: learning "$—",
    limited/fatigued/spent desaturation, over-capacity amber (Builder).
17. End Day button component: blue fill, 4px shelf / 3px travel, day sub-label, forfeit-warning
    state (static amber "2 AP UNSPENT").
18. MON–SUN week strip replaces the 5-dot track; add telegraphed state (amber tomorrow); reconcile
    done (blue2 vs strike-through) + live (ring vs shelf) treatments; fix rules §6 "gray dot".
19. Codex ROW (icon well + claim + state pill, redacted when UNSEEN); Field Note **-1 "hurts"** state;
    codex pill radius 12→99px (or record the exception).
20. People: print both numbers ("SAYS 84% · RUNS 61% (18 graded)"); calibration trait hidden as
    ?-pill until earned (style trait stays); candidate / uncalibrated-shimmer / empty-slot / rarity
    borders; face-chip desk variant (48–56dp); stop trait pills borrowing `.tag.urgency`.
21. Verb dock state set: armed (blue border), unaffordable (gray, cost legible), not-applicable
    (all five always shown); earmarked AP half-opacity preview.
22. Race meter rebuild: TWO bell lines (two-sided test); add too-early, called-early, bell-resolved,
    inconclusive carry-over, pinned/unpinned states; CONFIRMED/BUSTED/INCONCLUSIVE pin grades.
23. Upgrade tile (icon + name + effect line + price) + ONE blue price atom (green was moonlighting).
24. Atom extractions: pressable plate (btn.sec/verb/dchip, one template, radius →14px); meter bar
    (§0.5); spend-token (§0.4); bank → stat-plate; know-row; small-chip token (§0.2). Codify chip
    one-slot priority: Learning > Creative Fatigue > Creative Limited > Leader > none. Diag guess
    chips: selected/committed, CORRECT = **amber** fill, WRONG = wobble + spent-gray, ≥48dp plates.
25. Rules-doc sync: §5 pin interest to week-close first beat; §6 fixes from 13/14/18 above.

## B. WHEN THE COMPONENT FIRST APPEARS ON A REAL SCREEN
26. Card interaction states (first Builder/Desk screen): pickup/drag lift 1.15× @120Hz, slot-hover
    lean, snap ≤120ms + Voice haptic, inspect pop ~180ms; lifecycle transitions gated one-at-a-time
    to the End-Day ceremony queue.
27. BELL 7-beat ~1.1s setpiece (needle 350ms → 250ms freeze → stamp + foil sweep + Shout → verdict
    roll → pin grade → release); full Shout for clean races only, Voice for dirty; day_end only.
28. Pack-rip Shout setpiece: one-at-a-time flips, visible dup→IP conversion floats.
29. Resource ceremony beats: trust-pip burn (pop → desaturate → shelf sag, ~500ms, Voice;
    protected-burn sequenced burn-then-bonus); negative settle float (red, sinks ~700ms); IP pill
    zero/gain/spend as its own pack beat; bank rolls 2–4 ticks/s; interest = week-close first beat.
30. Day-close stinger: NET hero with sequenced spend→revenue→net roll; loss-day state (red net,
    minus-sign redundancy); bounded against Morning Report + Sunday week-close.
31. Chip lifecycle motion: mount pop (180ms) / dismount return; RE-LEARNING re-mount on `on_edit`;
    fatigue advance = dull double-knock; recovery silent; counts roll 300ms tabular-nums.
32. Knowledge ceremony: note mint snap ≤120ms one-per-queue-item + Voice; evidence pop + digit roll;
    OBSERVED→CANON ink wipe + gold star stamp; diag grade reveal ≤700ms, never blocking the skim.
33. People: proposal bubble pin-it snap → Pin atom + Voice; quiet END-DAY expiry; max one bubble;
    hunch/ledger rationale fingerprint; fired exit (return ~250ms + red severance float, Voice).
34. Director telegraph runtime: night forecast toast → all-day weather chip (status-chip instance)
    → quiet resolve. Shimmer overflow per §0.1 ruling; a learning ad's four metrics = one masked sweep.
35. On-device touch verification: 48dp buttons, verb tiles ~62px vs 56dp floor, diag plates ≥48dp.
36. Asset pipeline (first Defold build): rasterize curated Phosphor SVGs → white PNGs @1x/@2x →
    `icons.atlas`, runtime-tinted; Noto Emoji PNGs for card-art placeholders (art side only).
