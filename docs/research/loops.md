# Loops Research: Real-Time / Live-Management Design for an Ad-Account Sim

**Track:** loops | **Date:** 2026-06-05 | **Status:** research complete
**Question:** What does real-time add (and cost) for a card-driven ad-account sim on mobile, what time-compression feels right, and what loop structures should we build on?

---

## 1. Executive summary

Real-time is the right call for Addendum, but only in a **bounded, player-initiated** form. The authentic emotion of media buying is dashboard-watching — launching a creative and watching the numbers move — and that emotion only exists in real-time. But unbounded real-time on mobile (Cultist Simulator-style continuous timers) produces clutter, anxiety, and interruption-fragility that reviews of every relevant mobile port document. The strongest pattern in prior art is the **round structure**: a paused planning phase (play your cards), a compressed live phase of ~3–6 minutes with intervention verbs, and a debrief/draft phase — i.e., tower defense / Mini Motorways / Balatro structure with a live simulation in the middle instead of a wave or a hand. Time should be fully frozen when the app is closed (no FarmVille appointment mechanics), pause should be first-class, and a sim "day" should run roughly 30–60 seconds at 1× — putting a 7-day flight at one median mobile session.

---

## 2. The core question: what real-time buys, and what it costs

### 2.1 What real-time adds for an ad-account sim

1. **It IS the fantasy.** Running paid media is literally a live-monitoring job: you launch, then you watch spend, CTR, and CPA tick on a dashboard, resisting the urge to touch it too early. Turn-based abstracts away the exact emotion the game is about. Football Manager's entire match-day design exists because "watch your decision play out" is a different (and stronger) emotion than "read the result" — FM26 doubled down with a new between-highlights Match Overview screen precisely to deepen that live read-react loop ([footballmanager.com](https://www.footballmanager.com/fm26/features/where-storytelling-evolves-fm26s-match-day-experience)).

2. **Suspense and variable reinforcement without gambling.** A live A/B race between two ads is a contest you bet effort on, not money — Balatro-style casino energy with a defensible skill core. Watching an underdog creative claw back after the first noisy hour is a story turn-based can't tell.

3. **Wuselfaktor (ambient busy-ness).** Dinosaur Polo Club explicitly designs for the pleasure of watching little agents flow through a system you shaped ([Thumbsticks on the GDC 2023 talk](https://www.thumbsticks.com/hustle-and-bustle-how-mini-motorways-built-its-wuselfaktor/)). For Addendum, the funnel itself can be the Wusel: a stream of customer dots scrolling past your ad, some *stopping* (thumbstop made literal), some clicking, some converting. This is the visual abstraction layer that replaces realistic ad renders.

4. **Fatigue becomes felt, not told.** A winner visibly decaying — frequency climbing, the dots stopping less often — teaches creative fatigue viscerally. In a turn-based game decay is a table entry; in real-time it's a small tragedy you watch.

5. **It can teach the single most important media-buyer skill: don't react to noise.** Early data lies. A real-time window in which the leader flips mid-flight teaches the "peeking problem" (premature winner-calling) better than any tooltip. This is a genuinely unique pedagogical fit between subject matter and real-time simulation — turn-based resolution destroys it because results arrive pre-settled.

6. **Constant gentle stakes.** Alexis Kennedy on Cultist Simulator's timers: "once they were in, I liked the constant sense of menace they brought. There's always something running down; there's always something running out" ([Game Developer](https://www.gamedeveloper.com/design/why-the-i-cultist-simulator-i-devs-built-their-lovecraftian-game-on-a-house-of-cards)). A burning daily budget is Addendum's native version of this menace — thematically perfect, since spend ticks whether or not the ad works.

### 2.2 What real-time costs (the honest list)

1. **Anxiety and attention demands.** Cultist Simulator's mobile App Store reviews are the cautionary tale: "Get distracted by anyone or anything whilst the live timer is running? You lost your job!" ([UK App Store review](https://apps.apple.com/gb/app/cultist-simulator/id1439886655)). Mobile play is interruption-dense; any design where wall-clock inattention loses games will burn players.

2. **Idle gaps.** Shamus Young's critique of real-time-with-pause: if the game makes you wait between decisions, "Why do I end up waiting for the computer? This is backwards!" ([Twenty Sided](https://www.shamusyoung.com/twentysidedtale/?p=32829)). His rule of thumb survives: real-time works when the sim runs fine if you *don't* pounce on every decision (SimCity, tower defense), and fails when it constantly demands decisions it then makes you wait for. Addendum's live phase must be watchable-but-optional-touch, with dead air either compressed or filled by meaningful parallel work (prepping the next ad while one flies — the Overcooked "stay with the pot or prep the next order" tension, [Game Developer deep dive](https://www.gamedeveloper.com/design/game-design-deep-dive-building-truly-cooperative-play-in-i-overcooked-i-)).

3. **It punishes reflection — and Addendum is a data-reading game.** Reading a results table is the skill being taught; timers and table-reading fight each other. TapSmart's Cultist Simulator review: "make liberal use of the pause button… There's enough to be digesting here without the added pressure of multiple timers" ([TapSmart](https://www.tapsmart.com/games/review-cultist-simulator-beguilingly-odd-card-game/)). Pause must be free, instant, and stigma-free.

4. **Screen real estate and missed events.** Cultist Simulator on iPhone gets cluttered; zoomed-in players miss new events spawning off-screen with no indicator ([TouchArcade](https://toucharcade.com/2019/04/01/cultist-simulator-review)). A live ad-account board on a 6" phone must cap simultaneous live objects (3–5) and route every event through a persistent, glanceable feed.

5. **Some players simply hate timers.** Cook Serve Forever shipped "Chill Mode" (fail timers off) because a meaningful audience segment demanded it ([Game Developer](https://www.gamedeveloper.com/design/deep-dive-cook-serve-forever-and-difficulty-levels)). Budget for a no-pressure mode early; for a stealth-educational game the relaxed audience matters even more.

**Verdict:** real-time, but *contained*: bounded live windows the player starts deliberately, with pause as a first-class citizen and zero wall-clock coupling outside sessions.

---

## 3. Prior-art analyses

### 3.1 Cultist Simulator (Weather Factory / Playdigious mobile, 2018/2019) — the most relevant
- **Loop:** cards on an open tableau + a handful of "verb" boxes (Work, Study, Dream…). Slot cards into verbs; each verb runs a real-time timer (seconds to minutes); output is new cards. Money drains on a recurring timer. Pause anytime.
- **Why it works:** card-as-resource grammar makes abstract concepts tangible; timers create overlapping rhythms and "constant menace"; discovery of mechanics *is* the game ([Game Developer](https://www.gamedeveloper.com/design/why-the-i-cultist-simulator-i-devs-built-their-lovecraftian-game-on-a-house-of-cards), [GamesBeat](https://gamesbeat.com/the-terse-poetry-of-alexis-kennedys-cultist-simulator-card-game/)).
- **Mobile evidence:** port is well-reviewed (4.8★ US App Store, $2.99 as listed today; launched $6.99) and the timer loop suits short sessions, *but* phones get cluttered, grouped card-moves are painful, and off-screen events get missed ([TouchArcade](https://toucharcade.com/2019/04/01/cultist-simulator-review), [mspoweruser](https://mspoweruser.com/review-cultist-simulators-mobile-port-sacrifices-unbelievers-but-not-quality/)). Crucially: **game time only runs while the app is open.**
- **Lessons for Addendum:** (a) cards + timed verb slots is a proven grammar for "card-driven decisions inside live simulation" — an ad slotted into a *placement* with a flight timer is structurally identical; (b) cap simultaneous timers on phone; (c) freeze time outside the app; (d) obfuscation worked for cosmic horror but will infuriate learners — Addendum should invert it with legible feedback.

### 3.2 Game Dev Story / Kairosoft (2010 mobile)
- **Loop:** real-time tick of weeks/months/years; you make a batch of compositional choices (genre × type × staff × direction sliders — effectively a card combo), then watch development tick, then **babysit the live sales graph week by week**, restocking units ([Niahak's guide](http://www.niahak.org/quick-guide-game-dev-story-pc/), [StrategyWiki](https://strategywiki.org/wiki/Game_Dev_Story/Gameplay)).
- **Why it works:** "It's easy to get trapped in an endless cycle of waiting for a game to finish development so you can start on another one while waiting for the sales information" ([Maximum Utmost](https://maxutmost.com/review-game-dev-story/)). Two overlapping wait-loops with decisions at the seams = perpetual "one more week." Ron Gilbert called the combo system a truthy simplification of real budget allocation ([WIRED](https://www.wired.com/2010/12/game-dev-story/)).
- **Lessons:** the *interleave* is the compulsion engine — always have one thing resolving while another is being built. Addendum: one ad in flight while you assemble the next from cards. Also proof that combo-quality revealed via delayed scored feedback (review scores, sales) teaches pattern-matching — players learn genre/type synergies exactly the way we want players learning hook/audience resonance.

### 3.3 Mini Motorways / Mini Metro (Dinosaur Polo Club)
- **Loop:** continuous real-time sim; demand spawns uncontrollably; you redraw the network anytime; **every in-game week (~2–2.5 real minutes) ends with a choice of upgrades** ([Upgrades wiki](https://mini-motorways.fandom.com/wiki/Upgrades); week length per reviews ~2.5 min — medium confidence). Pause and fast-forward exist; mobile is a first-class platform (Apple Arcade).
- **Why it works:** "predictable chaos" — limited agency over the agents keeps the player designing systems rather than micromanaging ([Pocket Tactics interview](https://www.pockettactics.com/dinosaur-polo-club/interview)). The escalating crisis "drives the game to a conclusion" — runs *end*, which creates score, ritual, and retry. Imperceptibly slow zoom makes growth feel continuous ([GamesHub](https://www.gameshub.com/news/features/the-making-of-mini-motorways-and-the-futility-of-urban-development-4748/)).
- **Lessons:** (a) the **weekly reward heartbeat** (~2.5 min) is a proven mobile-scale rhythm — Addendum's "end of flight, draft a new card" should sit on the same cadence; (b) indirect control is right: you place ads/budgets, the simulated audience does what it does; (c) runs should be losable/endable — fatigue can be the force that ends a run the way unserviced demand ends Mini Motorways.

### 3.4 AdVenture Capitalist & idle math (Anthony Pecorella, GDC)
- **Loop:** number-go-up generators, multiplicative upgrades, prestige resets; offline progress computed by delta-time on re-login ([GDC Europe 2016 slides, "Quest for Progress"](https://media.gdcvault.com/gdceurope2016/presentations/Pecorella_Anthony_Quest%20for%20Progress.pdf), [GDC Vault](https://www.gdcvault.com/play/1023876/Quest-for-Progress-The-Math)).
- **Why it works:** exponential cost / exponential payoff curves produce constant "next purchase in sight"; prestige converts stalls into fresh starts. Idle conventions: offline earnings often capped (~8–12h is the common convention) specifically as a return trigger ([MindStudios](https://games.themindstudios.com/post/idle-clicker-game-design-and-monetization/)).
- **Lessons:** steal the *math curves* (escalating client spend targets, compounding account upgrades, possibly prestige as "sell the agency / start a new vertical") — but be deliberate about NOT taking the offline-appointment metagame (see §6). AdCap also proves raw ticking counters are intrinsically watchable; juice the odometers.

### 3.5 Football Manager (match engine + Mobile edition)
- **Loop:** turn-based management punctuated by a **watchable live event** compressed via highlights; you intervene from the touchline (mentality, subs, shouts) between highlights. FM26 added native Instant Result (skip watching entirely) and a Match Overview screen between highlights with click-to-jump-to-highlight ([Operation Sports](https://www.operationsports.com/football-manager-26-adds-instant-result-option-for-matches/), [footballmanager.com](https://www.footballmanager.com/fm26/features/where-storytelling-evolves-fm26s-match-day-experience)).
- **FM Mobile** is the streamlined "fly through seasons" build — fewer systems, faster ticks, instant-result prominent ([footballmanager.com compare page](https://www.footballmanager.com/compare-games), [FOOTY.COM](https://www.footy.com/blog/culture/fm21-mobile-vs-touch-vs-pc/)).
- **Lessons:** (a) **highlight compression** — don't compress time uniformly; show the moments that matter and skip the rest; (b) intervention verbs gain weight because they're scarce and live; (c) always offer instant-result *eventually* — veterans will demand it — but recognize that watching is where learning happens, so don't surface it early; (d) the mobile edition's existence proves the "same fantasy, shorter loop" reduction works commercially.

### 3.6 Tower defense (build phase vs live wave)
- Player-triggered waves let the player control pacing; countdown-to-wave creates pre-tension; mid-wave building keeps the live phase interactive ([Sean Duggan's gameplay-flow overview](https://medium.com/@sean.duggan/tower-defense-general-gameplay-flow-529b317a8ef9), [CraftMyGame wave systems](https://craftmygame.com/features/wave-spawn)).
- **Lessons:** the cleanest known solution to "planning needs calm, execution needs tension." Addendum's launch button = "start wave." Early-send bonuses (launching the next flight before the current one ends) can reward confident players, a standard TD trick.

### 3.7 Luck be a Landlord & Stacklands (the card sandboxes)
- **LBaL is actually turn-based** — spin, then choose, every few seconds; runs ~30 minutes; rent deadlines every few spins create escalating targets; the mobile port (portrait, $4.99) is widely considered the best way to play ([TouchArcade review](https://toucharcade.com/2023/07/25/luck-be-a-landlord-mobile-review-iphone-ipad-android/), [Google Play](https://play.google.com/store/apps/details?id=com.trampolinetales.lbal&hl=en_US)). Its lesson is cadence, not real-time: "a simple choice every few seconds. No waiting." Escalating rent = the perfect model for escalating client ROAS targets.
- **Stacklands is the real-time card sandbox**: drag-stack cards on a board; villagers auto-work; **a ~2-minute day timer ends in a feeding bill** ([Wikipedia](https://en.wikipedia.org/wiki/Stacklands), [Pixelated Playgrounds](https://www.pixelatedplaygrounds.com/sidequests/game-design-perspective-stacklands)). The 2-minute heartbeat with a recurring cost is a superb pacing device — directly analogous to a recurring payroll/ad-spend bill. No official mobile port exists (Steam/itch only — medium confidence), so its phone ergonomics are unproven.

### 3.8 Plague Inc (Ndemic, 2012) — underrated analog
- **Loop:** compose an "agent" from traits (card-like upgrade picks), release it into a real-time world map, watch spread, **tap DNA/cure bubbles as they pop up**, evolve mid-run. Speed controls + pause. 700M+ games played; built mobile-first ([Ndemic](https://www.ndemiccreations.com/en/22-plague-inc), [Kotaku](https://kotaku.com/plague-inc-makes-killing-billions-of-people-feel-educa-1732044365)).
- **Lessons:** (a) the **harvest bubble** is the best-known trick for keeping hands busy during a watching phase — Addendum can pop "insight" tokens off the live sim (tap to bank a learning: "Hook H over-indexes with Audience A"); (b) compose-then-release-then-tune is exactly Addendum's shape; (c) it's the strongest proof that *watching a simulation you configured* carries a mobile hit.

### 3.9 Two Point Hospital, plate-spinners, RimWorld
- **Two Point Hospital** (PC/console; no phone version — medium confidence) supports radically different pacing styles: pause-and-plan players and never-stop players both, via instant pause/slow/normal/fast ([gamertweak](https://gamertweak.com/how-to-speed-up-time-in-two-point-hospital/)); there's even an achievement for heavy pause use ("Ponderous Use of the Pause Button", [wiki](https://two-point-hospital.fandom.com/wiki/Ponderous_Use_of_the_Pause_Button)). Lesson: speed controls are an accessibility spectrum, not a feature toggle.
- **Plate-spinners** (Diner Dash, Tapper, Overcooked): formal analysis models every customer as a **decaying timer the player strives to keep full**, with tunnel-vision as the core failure mode ([Treanor & Nelson, FDG 2019](https://www.kmjn.org/publications/OrderFulfillment_FDG19.pdf)). Overcooked's key balance move: replace hard fails with a time-boxed score window so players get breathing room ([Game Developer](https://www.gamedeveloper.com/design/game-design-deep-dive-building-truly-cooperative-play-in-i-overcooked-i-)). Lesson: live ads ARE tables-with-hearts; cap how many can demand attention at once, and prefer score-loss to run-loss for missed interventions.
- **RimWorld's AI storytellers** are pacing directors that schedule crises against a dramatic arc ([overview essay](https://medium.com/@coyega1328/algorithmic-authors-rimworlds-ai-storytellers-as-agents-of-literary-genre-eff70ea4560c)). Lesson: Addendum should have a "market director" that schedules CPM spikes, competitor entries, and viral moments for drama, not pure RNG.

---

## 4. Time compression: anchors and a recommendation

Known anchors (verified where possible):

| Game | In-game unit | Real time | Ratio | Note |
|---|---|---|---|---|
| The Sims 4 | 1 day | ~36 min (default) | ~40× | 25 ms/sim-second ([EA forums](https://forums.ea.com/discussions/the-sims-4-general-discussion-en/game-speed-it-is-correct-this-count-yes-and-some-tips/278825)) — far too slow for our use |
| Mini Motorways | 1 week | ~2–2.5 min | ~4,000× | weekly upgrade ritual (medium confidence on exact seconds) |
| Stacklands | 1 "day/moon" | 2 min | — | day ends in a food bill ([Wikipedia](https://en.wikipedia.org/wiki/Stacklands)) |
| Game Dev Story | 1 week | a few seconds | ~10⁵× | sales graph bars are weekly; you restock weekly |
| FM match | 90 min | ~5–10 min of highlights | ~10–15× *effective* | non-uniform: highlights only |
| Cultist Simulator | verb actions | 10–60 s each | n/a | overlapping short timers, not calendar time |

**Recommendation (opinionated):**
- **Unit = the day.** Real media buyers think in daily spend/daily ROAS; days are the truthy abstraction.
- **1 sim day ≈ 30–60 s at 1×.** A 7-day flight = **3.5–7 minutes** ⇒ exactly one mobile session (see §7). At 45 s/day this is ~2,000× compression — the same family as Mini Motorways' rhythm.
- **Compress non-uniformly (the FM lesson) and make it diegetic:** rush through 1am–6am when the audience is asleep, dilate at peak hours and at events (first 1,000 impressions, budget threshold, fatigue inflection). Bonus: this *teaches dayparting* — the daily delivery curve becomes visible mechanically.
- **The Mini Motorways "Sunday choice" maps to end-of-flight:** every flight ends in a report + a draft pick (new card / upgrade). One reward heartbeat every 3–7 minutes.

---

## 5. Pause and speed controls

- **Pause is non-negotiable and must be free, instant, and unlimited.** Every relevant mobile port's reviews say players live in pause while reading state (Cultist Simulator, above). Addendum is a *data-reading* game — opening any metrics panel should implicitly pause (or offer to).
- **Speeds: pause / 1× / 2× / 4×.** Prior art shows players overwhelmingly use *faster*, rarely slower (Two Point's slow-mo is niche). Persist the player's chosen speed.
- **Auto-pause on app background, always.** Cheap, expected, and required by the no-wall-clock rule (§6).
- **Event-driven auto-slow:** when the market director fires an event (CPM spike, competitor launch), drop to 1×, zoom, and present the intervention choice with a *generous in-sim* countdown — bounded real-time-with-pause, avoiding Shamus Young's RTWP trap because the sim never *waits* on you otherwise.
- **Instant-result ("Trust the plan")** as an unlockable, FM26-style — but earn it late. Watching is the teaching channel; don't let players skip it before the patterns have landed.

## 6. Should the sim run while the app is closed? **No.**

- **Local-first premium games freeze time:** Cultist Simulator mobile, Balatro, Mini Motorways runs, LBaL runs. Balatro made ~$1M in week one and 5M+ units by Jan 2025 as a premium, fully session-bounded game ([PocketGamer.biz](https://www.pocketgamer.biz/balatro-exceeds-5-million-in-sales-on-all-platforms/)) — the commercial proof that mobile does not require retention timers.
- **Wall-clock coupling drags toward the FarmVille pattern:** wither windows (2.5× grow time, [FarmVille wiki](https://farmville.fandom.com/wiki/Wither)) are loss-aversion appointment mechanics ([Game Developer on wither](https://www.gamedeveloper.com/design/beyond-wither-supercompensation-in-games), [Adrian Crook](https://adriancrook.com/should-farmvilles-famous-wither-mechanic-be-left-to-rot/)) — they generate anxiety, not learning, and are wrong for a premium educational toy. The idle-genre convention of capping offline earnings at 8–12h exists purely as a return trigger ([MindStudios](https://games.themindstudios.com/post/idle-clicker-game-design-and-monetization/)) — a F2P retention goal we don't share.
- **One future-friendly exception:** an explicit, opt-in **"overnight flight"** (set it before bed, read the report tomorrow) could be a delight — appointment as gift, not threat: results can only be neutral-to-good (report + insights), never a punishment for lateness. Defer past v1.

## 7. Mobile session constraints (current data)

GameAnalytics' 2026 benchmark report (16,262 games, data through 2025): **median session 3.1–3.5 min; top-25% ≈5.2 min; top-10% ≈8 min; top-1% ≈22 min**; top-25% games see 5.3–5.7 sessions/day ([InvestGame PDF](https://investgame.net/news/pdf/2026-01-27-2026-mobile-pc-benchmarks_compressed/), [gamedevreports summary](https://gamedevreports.substack.com/p/gameanalytics-mobile-and-pc-game)). Board/card/puzzle genres over-index on retention and session count ([2025 report](https://www.gameanalytics.com/reports/2025-mobile-gaming-benchmarks)).

Design consequences:
- **The atomic loop (plan → flight → debrief) must complete in ≤5–7 minutes**, with a satisfying exit point (report + draft pick). Deeper players chain rounds (Balatro/LBaL model: ~30-min runs made of small rounds).
- **Every screen must be interruption-safe:** auto-pause + a one-glance "you are here" state on resume.
- **Multiple short sessions/day is the norm** — a persistent campaign across rounds (clients, deck, fatigue carrying over) rewards re-entry without requiring wall-clock appointments.

---

## 8. Catalog: concrete "live moment" mechanisms

1. **Ticking metrics / odometers** — spend, impressions, CTR, ROAS counters rolling live (Game Dev Story sales bars; AdCap number-go-up). Juice them: digit-roll, color pulses on threshold crossings.
2. **The live A/B race** — two ad variants head-to-head with racing bars; the race resolves at *statistical significance*, not a fixed timer (teaches sample size + the peeking problem). The single most Addendum-native mechanism; no direct prior art does this — closest is FM's match.
3. **Intervention verbs during the flight** — kill ad, boost budget, swap hook/creative card mid-flight, broaden audience, "scale winner" (clone into a new placement). Modeled on Motorsport Manager's live pit-strategy calls and reactions to weather/safety car ([App Store](https://apps.apple.com/us/app/motorsport-manager-mobile-3/id1346580540)) and FM touchline changes. Keep them scarce (2–3 tokens per flight?) so each is a real decision.
4. **Harvest bubbles → Insight tokens** — Plague Inc's DNA bubbles, reskinned: tappable moments that pop off the sim ("3 comments mention the hook — bank this insight?"). Keeps hands busy while watching; banked insights become deck-building knowledge (a learnings journal that is literally the player's growing skill).
5. **Director events with bounded decision windows** — CPM spike, competitor enters the auction, creative gets a viral comment, tracking outage (chaos!). RimWorld-storyteller scheduled, auto-slowed, generous timers.
6. **Threshold ceremonies** — ROAS crossing 1.0 (break-even bell), frequency crossing ~3 (fatigue klaxon; card art visually desaturates as it tires), budget pacing alerts. These make abstract metrics legible as *moments*.
7. **Timer slots (Cultist grammar)** — each placement is a verb-box; an ad card slotted in shows a radial flight timer and a burning budget. Production verbs (shoot new creative, research audience) run parallel timers so there's always something resolving (Game Dev Story interleave).
8. **End-of-day micro-report / end-of-flight report card** — the FM half-time moment; one-screen, plain-language verdicts with optional drill-down (matches "simple by default, deep on demand").
9. **Wuselfaktor funnel** — the ambient visualization: a scrolling stream of customer dots passing the ad; some stop (thumbstop), some click, some convert; fatigued ads visibly stop fewer dots. This is the live render of the abstraction — the "ad" never needs to be shown realistically.
10. **Plate-spinner load management** — multiple live flights as satisfaction/fatigue timers (Diner Dash tables); cap at 3–5 simultaneous; missed interventions cost score, never the run (Overcooked lesson).

---

## 9. Loop-structure patterns to build on

### Pattern A — "Draft → Flight → Debrief" (tower-defense round) — **recommended core**
*Named examples: tower defense build/wave, Mini Motorways weekly rhythm, Balatro blind/shop, LBaL rent deadlines.*
Paused planning (compose ads from cards, allocate budget) → player taps **Launch** → compressed live flight (3–6 min, interventions + insight bubbles) → report card + escalating client target check (rent/blind equivalent) → draft/shop. Run-based: fatigue + rising targets eventually end the run (Mini Motorways' "it has to end somewhere"). Fits sessions, fits Balatro energy, fits learning (tight hypothesis→test→read cycles).

### Pattern B — "The Live Desk" (continuous tableau)
*Named examples: Cultist Simulator, Stacklands, RimWorld.*
A persistent account board where ads, clients, and production tasks are cards in timed verb slots; time runs while the app is open; pause freely. Maximum simulation feel and the best long-game ("manage a whole account"), but the worst phone ergonomics (clutter, missed events) and the highest anxiety. **Use as the late-game campaign wrapper around Pattern A flights, not as the core.**

### Pattern C — "Match Day" (meta + watchable event)
*Named examples: Football Manager (incl. FM26 Instant Result + Match Overview), Motorsport Manager Mobile.*
Calm turn-based meta (clients, deck, research) punctuated by high-stakes live launches treated as matches: highlight compression, between-highlight overview screens, scarce touchline verbs, instant-result for veterans. **Steal its match-day presentation tech for Pattern A's flight phase** rather than adopting the whole structure.

### Pattern D — "Agency Rush" (plate-spinner mode)
*Named examples: Diner Dash, Overcooked, Game Dev Story babysitting, Cook Serve Forever's difficulty spectrum.*
Escalating simultaneous clients, each a decaying timer; pure triage skill; ends in predictable-chaos crisis → score. Too stressful as the core for a learning game, but a strong optional challenge mode that tests internalized patterns under pressure (and a natural "exam" for the educational arc).

**Recommended synthesis:** A is the core loop; C's presentation inside A's flight; B as the campaign meta once players have ~5 hours of fluency; D as an unlockable challenge mode.

---

## 10. Recommendations (condensed)

1. Build Pattern A (Draft → Flight → Debrief) as the core; one full loop ≤7 min.
2. 1 sim day ≈ 30–60 s at 1×; 7-day flights; non-uniform "highlight" compression with diegetic dayparting.
3. Pause free and unlimited; metrics panels imply pause; speeds 1×/2×/4×; auto-pause on background.
4. No wall-clock simulation when the app is closed. Ever (v1). Opt-in overnight flights later, gift-framed.
5. Cap simultaneous live objects at 3–5; persistent event feed; score-loss not run-loss for missed interventions.
6. A/B races resolve on significance, not timers — the flagship mechanic uniting fun and pedagogy.
7. Insight tokens (Plague-Inc bubbles) to keep hands busy and make learning collectible.
8. Market-director event scheduling (RimWorld), not raw RNG.
9. Escalating client targets as the run pressure (LBaL rent / Balatro blinds); fatigue as the natural run-ender.
10. Ship a Chill/no-timer mode and late-game instant-result; both audiences are real.

## 11. Open questions for downstream tracks
- Does the live phase render the funnel (dots) or the dashboard (charts) as primary? Prototype both; Wuselfaktor argues dots.
- Exact significance model for A/B race resolution (sequential testing made juicy) — needs the metrics/abstraction track.
- How much intervention is too much? (TD says mid-wave building is fine; FM says scarcity adds weight.) Needs playtesting with intervention-token counts 0/2/unlimited.
- Portrait vs landscape: LBaL and Balatro argue portrait one-handed is a mobile superpower; Cultist's tableau wants landscape. Pattern A can be portrait if the board is a column.

---

## Sources

- https://www.gamedeveloper.com/design/why-the-i-cultist-simulator-i-devs-built-their-lovecraftian-game-on-a-house-of-cards
- https://gamesbeat.com/the-terse-poetry-of-alexis-kennedys-cultist-simulator-card-game/
- https://toucharcade.com/2019/04/01/cultist-simulator-review
- https://mspoweruser.com/review-cultist-simulators-mobile-port-sacrifices-unbelievers-but-not-quality/
- https://www.tapsmart.com/games/review-cultist-simulator-beguilingly-odd-card-game/
- https://apps.apple.com/us/app/cultist-simulator/id1439886655
- https://apps.apple.com/gb/app/cultist-simulator/id1439886655
- https://www.wired.com/2010/12/game-dev-story/
- https://maxutmost.com/review-game-dev-story/
- https://www.gamedeveloper.com/production/-quot-game-dev-story-quot-7-valuable-lessons-for-game-developers
- https://strategywiki.org/wiki/Game_Dev_Story/Gameplay
- http://www.niahak.org/quick-guide-game-dev-story-pc/
- https://en.m.wikipedia.org/wiki/Game_Dev_Story
- https://www.pockettactics.com/dinosaur-polo-club/interview
- https://www.thumbsticks.com/hustle-and-bustle-how-mini-motorways-built-its-wuselfaktor/
- https://www.gameshub.com/news/features/the-making-of-mini-motorways-and-the-futility-of-urban-development-4748/
- https://www.gamedeveloper.com/audio/-i-mini-motorways-i-and-the-delicate-art-of-marrying-complexity-and-minimalism
- https://mini-motorways.fandom.com/wiki/Upgrades
- https://media.gdcvault.com/gdceurope2016/presentations/Pecorella_Anthony_Quest%20for%20Progress.pdf
- https://www.gdcvault.com/play/1023876/Quest-for-Progress-The-Math
- https://games.themindstudios.com/post/idle-clicker-game-design-and-monetization/
- https://www.operationsports.com/football-manager-26-adds-instant-result-option-for-matches/
- https://www.footballmanager.com/fm26/features/where-storytelling-evolves-fm26s-match-day-experience
- https://www.footballmanager.com/compare-games
- https://www.footy.com/blog/culture/fm21-mobile-vs-touch-vs-pc/
- https://medium.com/@sean.duggan/tower-defense-general-gameplay-flow-529b317a8ef9
- https://craftmygame.com/features/wave-spawn
- https://toucharcade.com/2023/07/25/luck-be-a-landlord-mobile-review-iphone-ipad-android/
- https://play.google.com/store/apps/details?id=com.trampolinetales.lbal&hl=en_US
- https://www.pocketgamer.com/luck-be-a-landlord/review/
- https://en.wikipedia.org/wiki/Stacklands
- https://www.pixelatedplaygrounds.com/sidequests/game-design-perspective-stacklands
- https://steamcommunity.com/app/1948280/discussions/0/3279195432654374953/
- https://www.ndemiccreations.com/en/22-plague-inc
- https://kotaku.com/plague-inc-makes-killing-billions-of-people-feel-educa-1732044365
- https://apps.apple.com/us/app/motorsport-manager-mobile-3/id1346580540
- https://en.wikipedia.org/wiki/Motorsport_Manager
- https://gamertweak.com/how-to-speed-up-time-in-two-point-hospital/
- https://two-point-hospital.fandom.com/wiki/Ponderous_Use_of_the_Pause_Button
- https://www.kmjn.org/publications/OrderFulfillment_FDG19.pdf
- https://www.gamedeveloper.com/design/game-design-deep-dive-building-truly-cooperative-play-in-i-overcooked-i-
- https://www.gamedeveloper.com/design/deep-dive-cook-serve-forever-and-difficulty-levels
- https://www.shamusyoung.com/twentysidedtale/?p=32829
- https://stanislav-stankovic.medium.com/game-mechanics-games-and-time-a85c2913319f
- https://stanislav-stankovic.medium.com/simulation-games-quirks-of-genre-adda9939aa3b
- https://medium.com/@coyega1328/algorithmic-authors-rimworlds-ai-storytellers-as-agents-of-literary-genre-eff70ea4560c
- https://farmville.fandom.com/wiki/Wither
- https://www.gamedeveloper.com/design/beyond-wither-supercompensation-in-games
- https://adriancrook.com/should-farmvilles-famous-wither-mechanic-be-left-to-rot/
- https://investgame.net/news/pdf/2026-01-27-2026-mobile-pc-benchmarks_compressed/
- https://gamedevreports.substack.com/p/gameanalytics-mobile-and-pc-game
- https://www.gameanalytics.com/reports/2025-mobile-gaming-benchmarks
- https://forums.ea.com/discussions/the-sims-4-general-discussion-en/game-speed-it-is-correct-this-count-yes-and-some-tips/278825
- https://www.pocketgamer.biz/balatro-exceeds-5-million-in-sales-on-all-platforms/
- https://www.pocketgamer.biz/balatro-approaches-1-million-in-seven-days-on-mobile/
- https://www.pocketgamer.biz/how-playstack-bet-on-balatro-and-won-big/
