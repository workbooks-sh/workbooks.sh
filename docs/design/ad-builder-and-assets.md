# The Ad Builder, the Asset Library, and the Production Pipeline (PROPOSAL, 2026-06-05)

**Status: author proposal (Shane, mid-mock-sweep), not yet ruled into v1.** Companion to [team-cards.md](team-cards.md) — together they form the production layer: **team → generates assets → library → builder → live ads.**

## 1. Campaigns vs ads — keep the real hierarchy, quietly

Stay as realistic as the real structure: **client = the account, lane = the ad set (audience), ad = the composition.** The builder should name these honestly (it's free metric literacy) without making the player manage campaign settings — the hierarchy is *displayed*, only the ad level is *built*. (This is already implicit in the wave machine; the builder makes it visible.)

## 2. The Ad Builder

A dedicated composition surface — **more than dropping cards into a pit**:

- **Drag-and-drop from the Asset Library** into the ad's slots (the established grammar: Hook + Visual + Format + Offer + ≤3 modifiers). Tap-to-inspect / drag-to-commit per the mobileux spec.
- **The composed ad renders as a stylized visual** — not a real ad, a legible abstraction assembled from the cards' art (the Late-Night Cable monitor mock: headline strip, visual region, CTA chip, format frame).
- **Anatomy flexes:** CTA button or none, headline strip, end-card on video formats — these are modifier-class choices, "little boosters," kept simple.
- **Strategist annotations live here** (see §6): icons/numbers on cards and slots explaining *what we're selling vs what tends to work for this lane* — recommendations, never auto-builds.

## 3. Assets and provenance — WHO made it is part of the card

Visual cards are **assets with provenance**: made by your staff motion-graphics artist, a hired UGC creator, or organic UGC. Provenance affects cost, quality (aspect strength), and fatigue character — and it's truthful (UGC vs produced is a real creative-mix decision).

**The production pipeline:** staff/contractors *generate* assets over time — you feed in the client's products, your team returns asset cards into the library. This is where team cards' "output" becomes concrete: a Production Studio hire doesn't abstractly "+capacity," it **mints asset cards on a cadence**. The library grows because you built a team that grows it.

## 4. Copy — the explicit v1 stance

**No free-text copywriting in v1.** Writing real copy and grading it (keywords/NLP) is the obvious trap: heavy to build, hard to grade honestly, and it would need an LLM or server — breaking local-first. Copy lives *inside* hook/angle cards (their names and flavor ARE the copy), and the reuse fantasy is preserved exactly as proposed: a social-proof asset minted by the product team is yours to reuse in any ad thereafter. Free-text copy can return post-v1 as an optional "pitch mode" if ever justified.

## 5. The composition budget — and why over-stuffing fails honestly

Every ad has a **capacity budget**; every card has a weight. You can compose over budget — with a penalty. This is truthful, not just a game rule: **overloaded ads underperform in reality** ("one ad, one job" is core practitioner wisdom — too many messages = no message). Mechanically: over-budget applies a legibility penalty to hook/hold (the ad is cluttered; people scroll past or bail). Teaching: focus beats more.

## 6. Strategist hypotheses — automated pattern-finding that doesn't steal the lesson

From the team layer (extends team-cards.md):

- **Strategists generate hypotheses** — auto-proposed Pins ("Call it: urgency beats trust on COLD for Thumbstop?"), suggested clean-test setups, and candidate patterns surfaced from your accumulated Field Notes. You can also *assign* one ("work the cookware lane").
- **Headcount and quality scale the engine:** more/better strategy hires → faster theorizing, more proposals per wave, higher proposal hit-rate (quality tiers = assurance levels).
- **The line that protects the pedagogy: propose, never decide.** Proposals are hypotheses, not answers — they still need launching, testing, and reading, by you. The player can always do everything manually; hiring buys *speed and coverage*, not truth.
- Late-game, this stacks with the existing mastery-gated automation stance (instant-resolve gated on Codex progress): automation is a *reward for demonstrated learning*, never a bypass of it.
- **Trait-driven variance (see team-cards.md):** each hire's traits (over/underconfident, creative/analytical) set their proposal stream's hit-rate bias, variance, and confidence framing. Proposals display claimed confidence; the hire's **graded track record** displays actual calibration — the gap between the two is readable, learnable, per-hire information. Recommendations stop being an oracle and become testimony from a witness whose reliability you establish.

## 7. Fatigue, extended to assets and combinations

Two extensions to the per-(card,lane) fatigue system:

1. **Alignment modulates wear rate** (mostly exists already): well-aligned assets fatigue slower. The resonance system's `fatigue_rate` carries this — strong lane-fit compositions could earn a wear discount, misaligned ones wear faster.
2. **Combination fatigue (the echo penalty, made mechanical):** reusing the *same combination* too often fatigues the ad faster than its parts — a wear term keyed on the composed set, not just the cards. This is the Andromeda-era diversity lesson from the domain research (near-duplicates stagnate; conceptual diversity wins) expressed as a felt mechanic: iterate the *combination*, not just the card.

## 8. Open questions (pivot review)

1. Capacity budget: per-format (video fits more than a static?) or flat? What's the over-budget penalty curve?
2. Asset generation cadence: per-wave mints, or commissioned (spend bankroll → asset arrives next wave)?
3. Provenance depth in v1: full maker system, or just a provenance *tag* with one effect each (staff = cheaper iterations, UGC creator = social_proof boost, organic UGC = cheap but high variance)?
4. Strategist proposal UX: a queue on the Brief screen, sticky notes in the builder, or both?
5. Does combination fatigue track exact sets only, or near-duplicates (1-card-different) at reduced weight? (Near-dup tracking is truer to Andromeda but costs a similarity measure.)

## 9. Mock plan (sweep additions)

- **Composition rules mock** (`ad-7r3.14`): capacity/weight budget + over-budget hook/hold penalty + combination-fatigue keyed on composed sets. Pure rules over existing systems.
- **Strategist hypothesis engine mock** (`ad-7r3.15`): reads ledger state + lane priors → emits proposed Pins/clean-test setups; quality tier scales proposal count and hit-rate; tests assert "propose-never-decide" (engine output is always a *suggestion object*, never a state change).
- Builder UI itself is design-phase work (`ad-mpn`): screen prototype in the component library.
