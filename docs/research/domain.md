# Domain Research: Creative Strategy & Paid Media Buying → Game Systems

**Track:** Domain | **Project:** Addendum (working title) | **Date:** 2026-06-05
**Status:** Research complete. All version/status-sensitive claims verified against live web sources June 2026; confidence flags inline.

---

## 1. Executive summary

The real job of a creative strategist / paid-social media buyer in 2025–2026 is a **portfolio-management loop over creative assets**, not an audience-targeting job. Platform AI (Meta's Andromeda retrieval engine, Advantage+ sales campaigns, TikTok Smart+) has absorbed targeting; the human's remaining levers are **creative volume, creative diversity, and fatigue management**. The practitioner's skill is pattern recognition across hooks × angles × formats × audience-awareness stages, expressed through a disciplined loop: research → ideate → brief/produce → structured test → read the funnel metrics → kill losers → modularly iterate winners → scale → manage decay.

This loop is *astonishingly* game-shaped. It already contains: a deck (creative library), card composition (hook/body/format/offer are literally swapped modularly by practitioners), hidden resonance patterns (audience segments respond predictably to angle types by awareness stage), a slot-machine-with-skill reveal (launch → watch live metrics), an escalating difficulty curve (fatigue + rising CPMs + scaling penalties), and a scoring system the entire industry already agrees on (ROAS). The abstraction layer in §8 maps every real concept to a proposed game concept and the lesson it teaches.

The biggest design tension found: **real conversion events are sparse** (median CTR ~2.2%, CVR ~1.6% — a purchase happens roughly 1 in 3,000 impressions). A truthful event-rate simulation would feel dead. Recommendation: keep the *ratios, orderings, elasticities, and metric names* real; compress event frequency and time. Truthy, not literal.

---

## 2. The practitioner loop (the real job, step by step)

Synthesized from Motion's creative strategy guide, Foreplay's strategist/brief guides, and agency playbooks (Pilothouse, Foxwell Digital). This is the loop the game must teach.

### 2.1 Research (voice-of-customer + competitive)
- Mine **customer reviews, Reddit threads, support tickets, ad comments** for the exact language customers use about the problem. Modern teams use AI to do this mining at scale (Pennock, 2025+).
- Spy on competitors via **ad libraries** (Meta Ad Library is public; Foreplay/Motion are the standard swipe-file tools). Strategists maintain swipe files of working ads tagged by hook/angle/format.
- Output: a map of pains, desires, objections, and proof points per customer segment.

### 2.2 Ideation: angles → hooks → formats
- An **angle** is the persuasive frame (pain relief, status, mechanism, value, identity). A **hook** is the first 1–3 seconds / first line that earns the stop. A **format** is the production container (UGC testimonial, founder video, static meme, carousel, demo).
- The standard direct-response skeleton: **Hook → Problem → Solution → Value prop → Social proof → CTA** (verified across Motion, UseClip, Billo 2025 guides).

### 2.3 Brief → production
- The creative brief is the single source of truth: concept, hook options, shot list, reference ads attached. The strategist's prep is the slow part; creator filming is fast (Foreplay brief guide).
- 2025–2026 reality: production cost per asset has collapsed (AI statics, modular editing), shifting the bottleneck to *deciding what to make* — i.e., the strategist's pattern knowledge.

### 2.4 Launch structured tests
- Dominant 2026 Meta pattern (Foxwell, Skaleit, Pilothouse, AdStellar all converge):
  - **Testing campaign**: ABO (ad-set budget) — one ad set per *concept*, 3–6 creatives each, equal budgets for fair comparison. Some teams use **cost cap** bids in testing to force ads to prove themselves at the target efficiency.
  - **Graduation**: a winner (commonly ~10–12 purchases at or under target CPA) gets duplicated **by post ID** (preserving social proof) into the **scaling campaign** — usually an **Advantage+ Sales Campaign (ASC)** with broad targeting, where Meta's algorithm allocates winner-take-most.
  - Named frameworks exist (e.g., Pilothouse's "3-3-3"); the common core is *fair-split exploration lane → algorithmic exploitation lane*.
- TikTok mirror: Campaign > Ad Group > Ad; ABO for testing (first 7–14 days), CBO/Smart+ for scaling; Smart+ wants ≥6 creative assets and ≥7 days before judging (TikTok official best practices).

### 2.5 Read performance (the funnel read — see §4)
- The skilled read is **localizing the failure**: which stage of the impression→stop→hold→click→convert funnel is leaking, because each leak implies a different fix.

### 2.6 Kill / iterate / scale
- **Kill rules** (practitioner heuristics, medium confidence on exact numbers): kill if spend exceeds ~1–1.5× target CPA with zero conversions; never judge inside the first day; don't edit a running ad (it resets learning).
- **Iterate winners modularly**: the canonical move is *keep the winning body, test 5–10 new hooks against it* (Motion, Billo, Uplifted all document this). One winning angle → 20+ hook variations. When a variation beats the control on hook rate, it becomes the new control.
- **Scale**: more budget into ASC, accept that marginal CPA rises with spend (diminishing returns), keep feeding new diverse concepts to offset fatigue.

### 2.7 Cadence
- High-spend DTC accounts ship **dozens to 50–100+ new assets per week** (adlibrary.com 2026; Meta's own case study quotes Dribbleup going from 3–4 to ~50 new creatives/week while holding performance). Brands testing 20+ new ads/month materially outperform those testing <10 (segwise/1ClickReport, directional claim, medium confidence).

---

## 3. Platform mental models (Meta + TikTok, 2025–2026)

### 3.1 Account hierarchy
- **Meta**: Campaign (objective, budget strategy) → Ad Set (audience, placement, optimization event, budget if ABO) → Ad (creative). **TikTok**: Campaign → Ad Group → Ad. Identical mental model.

### 3.2 Learning phase (the patience mechanic)
- An ad set needs **~50 optimization events within 7 days** to exit learning (Meta official guidance, still current 2026). During learning, delivery is exploratory and performance is volatile and typically worse.
- **"Learning Limited"** = stuck below signal volume. #1 causes: optimization event too deep in funnel for the budget, and **ad-set fragmentation** (five ad sets with 10 conversions each instead of one with 50 — none exit).
- **Significant edits reset learning.** This is the mechanical source of the #1 novice sin: fiddling.
- Budget floor heuristic: daily budget ≥ ~7 × target CPA to plausibly exit in a week. TikTok equivalent: ~$50/day per ad group minimum, optimization event with 20–50+ weekly occurrences.

### 3.3 Andromeda and the 2025–2026 creative-volume meta
- **Meta Andromeda**: next-gen ads retrieval engine, global rollout completed ~Oct 2025. It reads creative *content* and matches it to individuals; Meta credits it with an 8% ads-quality improvement (Meta for Business, Apr 2025).
- Consequence (verified via Meta's own "Creative Advantage" post + Jon Loomer + multiple agencies): **targeting is no longer the lever; creative diversification is.** Meta explicitly tells advertisers to upload more, conceptually different creatives and let the system match them to sub-audiences.
- Practical numbers circulating in 2026: 10–15 *conceptually distinct* assets per ASC; near-duplicate creatives (overlapping "entity IDs") stagnate; one ad set with 25 diverse creatives beat five ad sets of five each by ~17% conversions (vendor-reported, medium confidence on exact figures, high confidence on direction).
- **Advantage+ Sales Campaigns**: Meta reports ~9% lower CPA with streamlined ASC setup; Advantage+ creative (incl. GenAI variants) reports +11% CTR / +7.6% CVR (Meta-reported, treat as directional).
- **Broad vs targeted**: broad/Advantage+ audiences are the 2026 default for scaling; tight interest targeting survives mainly in niche/B2B and in testing isolation. The game should teach *creative is the targeting*.

### 3.4 TikTok specifics worth keeping
- Smart+ (launched into wide use Q4 2025) automates bidding/creative selection/audience expansion; wants ≥6 assets, ≥7 days, budget ~10× historical CPA to calibrate (TikTok official).
- TikTok fatigue is *faster* than Meta (creative half-life often 1–2 weeks vs 4–6+ on Meta; community consensus, medium confidence). Sound-on, native-feeling, hook in first 1–3 (officially "prioritize first 6") seconds.

---

## 4. The metrics stack (real names, real formulas, 2025–2026 benchmarks)

The game should use these exact names. Benchmarks are Meta ecommerce medians unless noted; sources: Varos-derived vendor reports, Triple Whale, AdAmigo, Vaizle, get-ryze (Jan 2026 data).

| Metric | Formula | What it diagnoses | 2025–26 benchmark (Meta, ecom) |
|---|---|---|---|
| **Hook rate / thumbstop rate** | 3-sec video plays ÷ impressions | Does the first 3 seconds earn a stop? | <25% weak · 25–30% solid · 30%+ best-in-class · 35–45% elite |
| **Hold rate** | 15-sec plays (or ThruPlays) ÷ 3-sec plays | Does the body keep attention? | <30% poor · 40–50% average · >50–60% strong |
| **CTR (link)** | link clicks ÷ impressions | Does it create desire to act? | median ~2.2% all-industry; ~1% is the classic floor |
| **CPC** | spend ÷ clicks | Cost of intent | global median ~$1.11 (Jan 2025–Jan 2026), peak $1.32 Nov 2025 |
| **CPM** | spend ÷ impressions × 1000 | Price of attention (auction pressure, seasonality) | median ~$14; **rose ~20% YoY**; Q4 spikes |
| **CVR** | purchases ÷ link clicks (or sessions) | Does the page/offer close? | ~1.6% (improved 8.3% YoY) |
| **CPA** | spend ÷ purchases | The cost of a customer | ecom median ~$30; $30–50 by vertical |
| **ROAS** | revenue ÷ spend | The score | **median ecom ROAS ~1.86×** (FY2025); 2.5–3×+ is "scaling comfortably" for most DTC margins |
| **Frequency** | impressions ÷ reach | Audience saturation | cold: keep <2.5 · retargeting: <4 |

**The diagnostic grammar (this is the core teachable skill — make it the puzzle grammar):**

| Pattern in data | Diagnosis | Real fix |
|---|---|---|
| Low hook rate | First frame/3s fails | New hook/thumbnail/opening line |
| High hook, low hold | Bait-and-switch hook or weak body | Align hook to body; tighten pacing |
| High hold, low CTR | Entertaining but no reason to act | Stronger CTA/offer/desire beat |
| High CTR, low CVR | Ad–landing-page mismatch, weak offer, wrong audience | Fix page/offer congruence |
| All good, CPA rising, frequency climbing | **Creative fatigue** | Refresh creative, expand audience |
| Everything mediocre at once | Wrong angle/audience entirely | Back to research; new concept |

**Sparse-event warning for the simulation:** at real rates, 1,000 impressions ≈ 300 stops ≈ 22 clicks ≈ 0.35 purchases. Purchases — the thing the score depends on — are rare and noisy. See §9.

---

## 5. Creative fatigue: what it actually looks like in data

- **Meta's official statuses** (Business Help Center, verified current): Ads Manager flags **"Creative limited"** when cost-per-result is above its historical level, and **"Creative fatigue"** when cost-per-result is **≥2× historical**, both tied to audience over-exposure. These are deterministic alerts on observed degradation, not forecasts.
- The empirical decay curve (multiple 2025 case studies, AdAmigo/Zentric/inBeat):
  - CTR can fall ~50% after 5–8 exposures per user.
  - Documented case: frequency 2.4 → 5.8 drove CPA $45 → $82; users at 7+ exposures converted at $147 CPA vs $38 at 1–2 exposures.
  - CPC spikes ~161% at frequency ~9.
  - ~80% of an ad's impact lands in the first two impressions per user per week.
- **Early-warning heuristics practitioners actually use**: CTR down ~10% week-over-week, or CPA up ~15% week-over-week → intervene.
- 2026 nuance: with broad/ASC delivery, fatigue increasingly shows as **CVR sag while CTR holds** (the algorithm finds ever-weaker marginal users) — subtler, later-funnel decay.
- Fatigue is *per-creative-concept per-audience*, recoverable by audience expansion or meaningful creative change; superficial recuts of a fatigued concept barely help (Andromeda reads content similarity).

**Design note:** fatigue is the game's natural difficulty escalator and anti-camping mechanic — your best card literally wears out, just like Balatro's escalating blinds obsolete static decks.

---

## 6. What separates good strategists from bad — the concrete patterns

### 6.1 The pattern library a good strategist carries

**Awareness-stage matching (Eugene Schwartz's 5 stages — the closest thing the field has to a law):**
| Audience state | What resonates |
|---|---|
| Unaware | Entertainment-first, pattern-interrupt, identity hooks |
| Problem-aware | Problem-callout hooks ("If your back hurts when you sit…"), problem/solution arcs |
| Solution-aware | Mechanism/differentiation ("works because of X"), us-vs-them comparisons |
| Product-aware | Social proof, testimonials, reviews, demos, objection-handling |
| Most-aware | Offers, urgency, bundles, retargeting reminders |

**Hook archetypes (battle-tested 2025–26 set):** question hook · contrarian/"us vs them" · POV/first-person · before/after reveal · listicle ("3 reasons…") · founder confession · demo-in-first-frame · social-proof-first ("40,000 five-star reviews…") · negative/warning hook ("Don't buy X until…") · curiosity gap · trend/meme remix.

**Format archetypes:** UGC selfie testimonial · street interview · podcast-clip style · founder/whiteboard talking head · unboxing/ASMR · green-screen reaction · static meme · "advertorial" long-copy static (skews older demos) · carousel before/after · comparison-table static · AI-generated static variants.

**Angle archetypes (motivations):** pain relief · time-saving · status/identity ("for people who…") · fear/risk-avoidance · social proof/FOMO · novelty/mechanism · price/value · occasion/gifting.

**Known cross-patterns (truthy, directional):** lo-fi native UGC > polished studio for cold DTC; older audiences respond to longer advertorial formats and bigger text; testimonials lift believability for warm traffic but underperform problem/solution for cold; offer-led creative dominates retargeting and Q4; creative quality drives ~3× the sales impact of frequency (EDO/Affinity 2025).

### 6.2 Behavioral separators

| Bad strategist | Good strategist |
|---|---|
| Judges ads on day 1; kills inside learning phase | Respects significance floors (spend ≥ 1–1.5× CPA, ~50-event signal) before verdicts |
| Edits live ads (resets learning) | Launches new variants alongside; never touches winners |
| Tests 5 recolors of one ad and calls it testing | Tests *conceptually distinct* angles; knows pseudo-diversity stagnates under Andromeda |
| Chases CTR or hook rate as the goal | Optimizes CPA/ROAS; uses upper-funnel metrics only as *diagnostics* |
| Fragments budget across many ad sets | Consolidates signal; clean test lanes, single scale lane |
| Iterates losers ("just needs a better hook") | Kills losers fast; iterates *winners* modularly (new hooks on proven body) |
| No tagging/naming discipline | Names/tags every ad by concept-hook-format-creator so patterns are queryable later |
| Reacts to fatigue after CPA doubles | Watches frequency + week-over-week CTR/CPA deltas; refreshes proactively |

That right-hand column is, almost verbatim, the game's intended skill curve.

---

## 7. Training pathways today (our competition)

| Offering | Format | Price (verified June 2026) | What it teaches |
|---|---|---|---|
| **Dara Denney — Performance Creative Master Course** | Self-paced video, monthly updates | **$899 one-time** | The creative-strategist role end-to-end: research, briefs, iteration, reporting |
| **Motion — 2026 Creative Strategy Bootcamp** | 8-week cohort (Mar 2026), expert instructors incl. Denney | **Free** (Motion's SaaS funnel) | Creative analysis, testing, big-bet prioritization |
| **Motion — Thumbstop newsletter** | Weekly | Free (50k+ readers) | Ongoing meta/patterns |
| **Foxwell Digital courses** (Scaling FB/IG Ads, Ad Buyers Bundle) | Self-paced | ~low hundreds per course/bundle (varies) | Media buying, account structure, scaling |
| **Foxwell Founders community** | Private community, 550+ members managing $1B+/mo | **$547/mo or $6,000/yr** | Live meta: what's working now |
| **CTC ADmission** | Membership + playbooks | ~$127 (Lite) to ~$299/mo (promos vary) | Ecom growth, forecasting, ad account structure |
| **Meta Blueprint certification** | Official cert exams | ~$99–150/exam (low confidence on current exact fee) | Platform mechanics, vocabulary |
| **HubSpot/CXL/etc. paid media courses** | Self-paced | Free–$1,500 | Fundamentals |
| YouTube/newsletter autodidact path | Free | $0 | Unstructured; no feedback loop |

**Key gap our game exploits:** every one of these is *content about* the loop. None give a **safe, fast, repeatable practice environment with ground truth** — you otherwise need a real ad account and thousands of dollars of spend to develop the pattern-recognition reflex. (A creative strategist's median US salary is roughly $93k–$131k depending on source — the skill has real market value, which legitimizes "stealth training" positioning.)

---

## 8. THE ABSTRACTION LAYER: real concept → game concept → lesson

Keep every metric's **real name** on screen (transferable literacy), with a simple visual as the primary read and the number as the secondary read.

| Real concept | Proposed game concept | Simplest legible presentation | What the player learns |
|---|---|---|---|
| Ad = hook + body/angle + format + offer | **Card composition**: an Ad = Hook card + Angle card + Format card (+ Offer card slot) | Cards snap together into one "Ad" unit, Balatro-style | Ads are modular; iteration means swapping parts, not starting over |
| Creative library / swipe file | The deck/collection; new cards earned via "research" actions | Collection screen with tags | Research feeds ideation; library breadth = optionality |
| Audience with hidden preferences | Per-client **resonance matrix** (hidden weights: awareness stage × angle/hook/format affinities), discoverable only through testing | An audience "crowd" blob; segments revealed as silhouettes as you learn them | Pattern discovery via A/B testing is THE job |
| Awareness stages (Schwartz) | Audience segments at different stages; stage mix shifts as the account matures and saturates | Crowd tinted by stage (cool→warm colors) | Match angle to awareness stage; cold ≠ warm creative |
| Funnel: impression→stop→hold→click→convert | **The pipeline**: a particle stream of viewers flowing through gates; each gate's pass-rate = the real metric | Animated funnel; each gate labeled with the real metric name + % | Decompose performance; localize the leak |
| Hook rate / thumbstop | **Stop meter** on gate 1 | "STOP" meter, % big and bold | First 3 seconds dominate; hooks are tested first |
| Hold rate | **Hold meter** on gate 2 | Watch-bar that drains | Hook must match body or viewers bounce |
| CTR / CPC | **Click gate** + cost ticker | Click % + $ per click | Attention ≠ intent |
| CVR / CPA | **Checkout gate** + cost-per-customer | Customer counter + big CPA number | The page/offer closes, not the ad alone |
| ROAS | **The score multiplier** | Balatro-style mult: revenue ÷ spend | Everything reconciles to ROAS |
| CPM / auction | **Price of eyeballs** ticker; drifts up over a run; spikes in "holiday season" events | $/1000 ticker on the spend dial | Attention is bought at auction; costs rise; seasonality |
| Frequency / saturation | Crowd members visibly "tagged" after exposures; **frequency stat per ad** | Saturation rings/heat on the crowd; freq number | Same people seeing it again converts worse |
| Creative fatigue ("Creative limited/fatigue" statuses) | **Freshness bar** on each live ad that decays with cumulative impressions to the same crowd; status chips appear at real thresholds (CPA >1×, ≥2× historical) | Draining freshness bar; yellow "LIMITED" / red "FATIGUE" chips, same words Meta uses | Winners decay; refresh proactively; doubling CPA = dead |
| Learning phase / 50 events | **Calibration**: new ad's meters shimmer/static for its first ~N conversions; metrics unreliable; touching the ad resets it | "CALIBRATING…" shimmer; progress ring to 50 | Don't judge or fiddle early; signal needs volume |
| Learning Limited / fragmentation | Splitting budget across too many simultaneous tests → none finish calibrating | Rings all stuck at 30% | Consolidate signal |
| Testing vs scaling structure (ABO test → ASC scale) | **Test Bench** (fair-split lanes, small spend) vs **Scale Engine** (one big lane, winner-take-most, algorithm-driven) | Two distinct board zones; drag a proven ad from Bench to Engine | The graduation workflow; test fair, scale greedy |
| Broad targeting / Andromeda creative-diversity meta | Scale Engine delivery quality scales with **conceptual diversity** of live ads; near-duplicate cards get an "echo" penalty | Diversity meter on the Engine; duplicate cards visually grey out | Creative IS the targeting; recolors aren't diversity |
| Statistical noise / significance | Binomial noise on all gates; early numbers wobble visibly, tighten with volume | Confidence shading: blurry number → sharp number | Small samples lie; wait for the number to focus |
| Kill/iterate/scale decisions | Core verbs: **Kill** (refund partial budget), **Iterate** (clone ad, swap one card, keeps body's proven stats prior), **Scale** (move to Engine, bigger spend) | Three big buttons on each live ad | The decision loop itself |
| Modular hook iteration | Iterating preserves the body card's learned resonance; only the swapped card is uncertain | Cloned ad inherits sharp meters except the new card's | Iterate winners, one variable at a time |
| Client / account | A **run**: client brief = product, audience, target CPA/ROAS "blind," budget | Client card with goal: "ROAS 2.0 at $5k spend" | Goals are efficiency-at-volume, not just efficiency |
| Scaling penalty (diminishing returns) | Marginal CPA rises as spend grows within a run | CPA creeps as spend dial rises | Efficient-at-$100/day ≠ efficient-at-$1k/day |
| New creative cadence | Card acquisition over time (research points, client growth, "creator" contacts) | Booster-style unlocks tied to progression | The job never stops feeding the machine |
| Q4/holiday CPM spike, competitor pressure | Timed run modifiers/events | Event banners: "Holiday auction: CPM +40%, CVR +25%" | Macro context changes the math |

**Presentation principle:** the funnel-with-particles is the single most important UI invention to get right — it makes every real metric *visible as a place where little people fall out of a pipe*, which is exactly the mental model professionals carry.

---

## 9. Essential-to-simulate-truthfully vs safely-fakeable

### Must be truthful (these ARE the lessons — get the shape right)
1. **Funnel decomposition** — independent-ish stage rates that multiply; fixes are stage-specific.
2. **Hook dominance** — first-gate variance is the largest lever; hook testing has the best ROI.
3. **Resonance = angle × audience-awareness-stage match** — the hidden pattern system must follow Schwartz-like structure, not arbitrary combos, or the transferable learning evaporates.
4. **Fatigue & frequency** — winners decay with exposure; decay accelerates with frequency; recovery requires real novelty or new audience.
5. **Learning phase / signal volume** — early data is noise; edits reset; fragmentation starves signal.
6. **Noise & significance** — early metric wobble must be real randomness the player learns to wait out (tunable signal-to-noise per difficulty).
7. **Diversity > micro-targeting** (the 2026 meta) — conceptual diversity rewarded, pseudo-diversity penalized.
8. **Diminishing returns to scale** — marginal CPA rises with spend.
9. **Iteration economics** — iterating a winner is higher-EV than a fresh concept, but exploration is mandatory because of fatigue (a clean explore/exploit dilemma).
10. **ROAS as the reconciling score** — and the tension that upper-funnel metrics can look great while ROAS fails.

### Safely fakeable / simplifiable (truthiness survives)
- **Auction internals** (bid types, pacing, second-price mechanics) → a drifting CPM number is enough; cost cap vs lowest-cost can be a late-game unlock.
- **Attribution windows** (1-day vs 7-day click, view-through, incrementality) → game has ground truth, so skip entirely at first; could become an "advanced mode" lesson where the dashboard lies slightly.
- **Pixel/CAPI/tracking plumbing** → omit.
- **Placement-level optimization** (feed vs reels vs stories) → fold into Format cards.
- **Exact dollar magnitudes** → relative values matter; rescale freely.
- **Event sparsity** → MUST be compressed. At real rates a purchase is ~1/3,000 impressions. Multiply base rates (e.g., show real % on meters but run the particle sim at 10–50× density) and compress time (a "day" = seconds). Keep orderings and elasticities real.
- **Landing page/website** → a single "store quality" stat per client, or an Offer card property.
- **Creative production** (briefing, creators, editing) → collapsing to card acquisition/crafting is fine; the decision layer is the lesson, not the production layer.
- **Platform multiplicity** (Meta vs TikTok) → one abstract platform first; TikTok-flavored "fast-decay, hook-heavier venue" is a clean expansion lever later.

### Do NOT import (anti-lessons / scope traps)
- Literal gambling framing on spend (variance must be learnable, not slot-luck) — keep casino *feel*, not casino *math*.
- Real brand names/real ad renders (legal + the user's explicit no-AI-generation constraint). Use fictional analogs of mid-tier DTC brands (cookware, western boots, basics apparel — per project preference for True Classic/Caraway/Tecovas-style exemplars, fictionalized).
- Audience demographic micro-targeting UI as a primary mechanic — it would teach an obsolete 2018 skill.

---

## 10. Open questions for the design track

1. **Real-time loop shape**: practitioner reality is check-ins (morning metrics review, weekly creative review), not constant attention. A compressed-time "live shift" punctuated by report cards may map better than true always-on real-time. The learning-phase shimmer gives a natural "wait" rhythm.
2. **How hidden should the resonance matrix be?** Real strategists never see ground truth — but a game probably needs end-of-run reveals ("the audience was 60% problem-aware; your mechanism angle never had a chance") for the lesson to land. Recommend: hidden during play, revealed in post-run autopsy.
3. **Card grammar arity**: 3 slots (Hook/Angle/Format) is learnable; 5 (+Offer, +Audience venue) is realer. Start at 3, unlock slots with progression — mirrors how juniors actually learn the job.
4. **Numbers literacy ramp**: meters-only → meters+percentages → full dashboard mode. The "option to go deeper" requested in the concept maps to progressive disclosure of the real Ads-Manager-style table.

---

## 11. Sources

- Meta for Business — The Creative Advantage: Unlocking the Power of Diversification with Meta Andromeda (Apr 2025): https://www.facebook.com/business/news/the-creative-advantage-unlocking-the-power-of-diversification-with-meta-andromeda
- Meta Business Help Center — Creative Fatigue Recommendations in Ads Manager: https://www.facebook.com/business/help/1346816142327858
- Jon Loomer — Creative Fatigue: What It Is and How to Prevent It: https://www.jonloomer.com/creative-fatigue-meta-ads/
- Jon Loomer — Meta Andromeda and Creative Diversification: https://www.jonloomer.com/meta-andromeda-creative-diversification/
- Motion — What is Creative Strategy? 7 Steps & Examples for DTC: https://motionapp.com/blog/creative-strategy
- Motion — Key creative performance metrics: https://motionapp.com/blog/key-creative-performance-metrics
- Motion — Creative Iterations Guide: https://motionapp.com/blog/creative-iterations-for-winning-ads
- Motion — 2026 Creative Strategy Bootcamp (free, 8-week): https://motionapp.com/2026-creative-strategy-bootcamp
- Motion — Thumbstop newsletter: https://motionapp.com/thumbstop
- Dara Denney — Performance Creative Master Course ($899): https://dara-denney-s-school2.teachable.com/p/performance-creative-master-course
- Foxwell Founders membership ($547/mo, $6,000/yr): https://foxwellfounders.com/ and https://foxwelldigital.podia.com/foxwellfounders
- Foxwell Digital — Meta Creative Testing Frameworks Winning in 2026: https://www.foxwelldigital.com/blog/the-meta-creative-testing-frameworks-top-brands-use-in-2026
- Pilothouse — 3-3-3 Creative Testing Framework: https://www.pilothouse.co/post/meta-creative-testing-framework-the-3-3-3-approach-to-finding-winners
- Skaleit — ABO vs CBO: Test and Scale Meta Ads 2026: https://skaleit.agency/blog/abo-vs-cbo-test-scale-meta-ads/
- TheOptimizer — Cost Cap vs Bid Cap 2026: https://theoptimizer.io/blog/meta-ads-bidding-in-2026-cost-cap-vs-bid-cap-and-when-to-use-each
- Wonderful — Meta Ads Learning Phase 50 Conversions Per Week: https://www.usewonderful.com/blog/meta-ads-learning-phase-50-conversions-per-week-help-center
- Cometly — Facebook Ads Learning Phase guides: https://www.cometly.com/post/facebook-ads-learning-phase-stuck
- TikTok Ads Manager — Best practices for Smart+ Web campaigns: https://ads.tiktok.com/help/article/best-practices-for-smart-plus-web-campaigns
- TikTok Ads Manager — Creative best practices: https://ads.tiktok.com/help/article/creative-best-practices
- Vaizle — Hook Rate and Hold Rate: Formulas and Benchmarks: https://insights.vaizle.com/hook-rate-hold-rate/
- Billo — From Hook Rate to Hold Rate: https://billo.app/blog/hook-rate-to-hold-rate/
- Billo — Ad Hooks That Scale (1 angle → 20 variations): https://billo.app/blog/ad-hooks-variations/
- Glued — Hook Rate vs Hold Rate Guide: https://www.glued.me/blog/hook-rate-vs-hold-rate-guide
- AdAmigo — Meta Ads Frequency Benchmarks (fatigue cases): https://www.adamigo.ai/blog/meta-ads-frequency-benchmarks-when-ads-start-fatiguing
- AdAmigo — Meta Ads CVR Benchmarks by Industry 2026: https://www.adamigo.ai/blog/meta-ads-conversion-rate-benchmarks-industry-2026
- Get-Ryze — Meta Ads Cost Benchmarks by Industry 2026: https://www.get-ryze.ai/blog/meta-ads-cost-benchmarks-by-industry-2026
- Triple Whale — Facebook Ad Benchmarks by Industry: https://www.triplewhale.com/blog/facebook-ads-benchmarks
- Segwise — Meta Andromeda Update: 2026 Creative Strategy Playbook: https://segwise.ai/blog/meta-andromeda-update-creative-strategy-2026
- Dataslayer — Every Meta Ads Change 2025–2026 changelog: https://www.dataslayer.ai/blog/meta-ads-changes-2025-83-updates-that-changed-facebook-advertising-forever
- Uplifted — Becoming a Creative Strategist (skills/salary): https://www.uplifted.ai/blog/post/the-ultimate-guide-to-becoming-a-creative-strategist-skills-salary-and-career-path
- Uplifted — Hook Iteration practitioner guide: https://www.uplifted.ai/blog/post/hook-iteration-the-practitioners-guide-to-finding-and-scaling-top-performing-ad-
- Foreplay — Creative Strategist career guide: https://www.foreplay.co/post/creative-strategist
- Foreplay — Guide to effective creative briefs: https://www.foreplay.co/post/guide-to-creating-an-effective-creative-brief
- ADmission (CTC) — membership/Lite pricing: https://offers.youradmission.co/admission-light1742841732341
- Glassdoor — Creative Strategist salary: https://www.glassdoor.com/Salaries/creative-strategist-salary-SRCH_KO0,19.htm
- ZipRecruiter — Creative Strategist salary: https://www.ziprecruiter.com/Salaries/Creative-Strategist-Salary
- TheCMO — 9 Best Paid Media Courses 2026: https://thecmo.com/career/best-paid-media-courses/
- adlibrary.com — Hold rate / AI ad creative for DTC (50–100 assets/week claim): https://adlibrary.com/posts/hold-rate and https://adlibrary.com/posts/ai-ad-creative-for-dtc-brands
