# Flows v0.1 — the turn-based loop (post-pivot)

Source of truth for loop structure until docs/01 is revised (DECISIONS 2026-06-05: turn-based days + AP). Landscape. Built from design-language v0.1 components only.

## The loop at one glance

```
TITLE
  └─ NEW RUN ─→ CLIENT SIGNING (meet the client, see the week ladder)
        └─→ WEEK BRIEF (the contract: target ROAS/$, spend floor, Mon–Sun strip)
              └─→ ╔═ THE DAY (the turn) ═══════════════════════════════╗
                  ║ MORNING — plan & act, AP budget (base 3)           ║
                  ║   1 AP: launch new ad (→ AD BUILDER)               ║
                  ║   1 AP: iterate a winner (clone, swap one card)    ║
                  ║   1 AP: boost · swap-live (the costed sin) ·       ║
                  ║         shop visit · hire/fire · assign strategist ║
                  ║   FREE: kill an ad (celebrated) · pin a race ·     ║
                  ║         diagnose (1st/day) · inspect anything      ║
                  ║        ─── END DAY (the commit) ───                ║
                  ║ NIGHT — resolution ceremony (the settle pass):     ║
                  ║   each ad settles one at a time → races advance    ║
                  ║   (the BELL can ring here) → fatigue ticks →       ║
                  ║   learning progresses → weekday stinger →          ║
                  ║   director event lands if scheduled                ║
                  ║ MORNING REPORT — 3 lines: what changed, Maya's note║
                  ╚══════════ × 7 days (Mon → Sun) ════════════════════╝
              └─→ WEEK CLOSE: brief check → pass (fee) / miss (pip)
                    └─→ AUTOPSY: pins graded · notes minted · guess-first
                          └─→ NEWSSTAND (between weeks)
                                └─→ next WEEK BRIEF · next CLIENT · or…
RUN END: CASE STUDY (won) / FIRED (lost) → full matrix reveal → Codex → TITLE
```

## Why this paces better than live

- **The day is the heartbeat**: ~60–90s of player time (plan 30–60s, ceremony 15–20s, report 5s). Seven heartbeats per week.
- **The week is the session**: ~8–10 min with a hard, satisfying close (brief check + autopsy + shop). Clean exit at EVERY day boundary too — autosave is structural.
- **AP makes the turn real**: the day ends when your attention is spent, not your money. Rich players can't brute-force; the explore/exploit tension lives in 3 choices/day. (Tunables: base AP 3; team capacity +1; unused-AP carryover = open question.)
- **Nothing streams.** The market only moves at night, and the night is a *ceremony* — sequenced, one ad at a time, the settle pass as the master pattern. Watching is replaced by *anticipating*.
- **The bell rings at night.** Race significance is evaluated at day resolution (exactly where the sim already looks — 0a math untouched). Pin in the morning, sweat at night.

## The weekday system

Days have identity; the strip reads MON TUE WED THU FRI SAT SUN.

| Day | Flavor (tunable, truthy-directional) |
|---|---|
| Mon | slow start — volume −10% |
| Tue–Thu | baseline |
| Fri | competitive — CPM +10% |
| Sat–Sun | scroll days — volume +25%, CPM −10% |

Director events are **day-scoped** ("WED: competitor sale — CPM spike all day"), telegraphed the night before — no countdowns, just tomorrow's weather.

## Screens (landscape, in flow order)

| # | Screen | Job | Built from |
|---|---|---|---|
| 1 | **Title** | new run / continue / codex | score plate, buttons |
| 2 | **Client Signing** | meet client, accept the engagement | client card, brief plate, button |
| 3 | **The Desk** ★home | the day: played-ads row center, score plate + bankroll left, day strip (weekdays) top, AP + verb context, hand/library at bottom edge, **END DAY** right | nearly everything |
| 4 | **Ad Builder** | compose: 4 slots + library shelf + live projection chain | component cards, slot stack, stat blocks |
| 5 | **Night Resolution** | the ceremony overlay on the Desk | settle floats, chips, race meter, bell, stingers |
| 6 | **Autopsy** | week close: pins graded, guess-first chips, notes minted | pins, diag chips, field notes |
| 7 | **Newsstand** | 2 singles + 2 packs + 1 upgrade | pack, price tags |
| 8 | **Team Board** | hire/fire, traits, track records | hire cards, proposal bubbles |
| 9 | **Codex** | the curriculum tracker (drawer, any time) | codex rows, field notes |
| 10 | **Run End** | case study / fired + matrix reveal | everything ceremonial |

Navigation rule: **The Desk is home**; 4–9 are excursions that return to it. No tab bar — movement is diegetic (tap the pack on the desk → Newsstand; tap Maya → Team Board).

## How a run STARTS (first 90 seconds)

1. Title → **Play**. 
2. Client Signing: one client offered (later: choice of 2). Their card flips up: vertical, vibe, the week ladder ("Week 1: ROAS 1.3 · Week 2: 1.45"). **Sign** (chunky press).
3. Week Brief stamps onto the desk → MON lights up → hand slides in (5 starter cards) → AP dots fill (●●●) → Maya's first proposal bubble ("Cold lane — open with a problem hook?").
4. First action is guided: **Build your first ad** (1 AP) → Builder teaches slots by doing.
5. Launch → back to desk → the ad sits there, Learning chip shimmering → **END DAY** pulses once.
6. First Night Resolution: the ad settles (+$ float), stinger, report. Day 2 begins. *Now they know the whole game.*

## Open questions (for the skeleton to answer)

1. Does the Desk hold 2 lanes on screen (landscape split) or one lane with a swipe?
2. End Day placement & weight — right-edge button vs center-bottom lever?
3. Morning Report: separate beat or folded into the ceremony's last card?
4. AP carryover / overflow → interest? (lean: no carryover, keep days crisp)
5. Does diagnosing stay free-first-per-day under AP, or become 1 AP always?
