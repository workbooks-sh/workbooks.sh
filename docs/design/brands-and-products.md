# Brands, Products, and the Layered Art System (PROPOSAL, 2026-06-05)

**Status: author proposal (Shane), captured mid-design-phase. v1 rulings at next review.**

## 1. Brand = the character you pick

The brand is the character select — the deck choice, in Balatro terms. Each brand has:
- a **vertical** (skincare, makeup, software/SaaS, cookware, apparel…),
- a **starting product** (or a small set; you pick which one you're selling first),
- its own personality/art identity.

Picking a brand sets your run's flavor, audience priors, and product economics — the way picking a deck sets a Balatro run.

## 2. Product categories and the product tech tree

Pre-set **product categories with pre-products** the player picks from. From the starting product, the run can **develop new products** along a tech tree:

```
SKINCARE BRAND:  cleanser ──→ serum ──→ SPF ──→ bundle/subscription
MAKEUP BRAND:    tinted balm ──→ palette ──→ kit
SOFTWARE BRAND:  free tool ──→ pro tier ──→ team plan
```

Mechanically (mapping to existing sim, to be ruled): products are what offers sell — a product defines **AOV, CVR character, and which Offer cards exist**. New products = new offer/economy space unlocked mid-run (the tech tree is progression that broadens the *sellable*, complementing cards that broaden the *sayable*).

## 3. ⚠ The identity tension (needs a ruling)

Current fiction: you're a **strategist serving clients**. This proposal reads as **you own/operate the brand**. Options:
- (a) **Brand-as-client-character**: clients ARE the brand characters; "signing" one = picking your character for the engagement. Tech tree = the client's roadmap you unlock for them. (Smallest change; keeps agency fiction + firing/pips.)
- (b) **Brand-as-self**: drop the agency frame; you run the brand. (Bigger pivot; pips/briefs need re-fiction.)
Lean (a) until ruled — it keeps every built system and makes the client roster the character roster.

## 4. The layered art system (the big production idea)

Card art is **composed from alpha-cut layers**, not drawn per-card:

```
[SETTING layer]  forest · kitchen · gym · studio
   + [PERSON layer]  UGC creator (alpha cutout) · founder · hand model
   + [PRODUCT layer]  the brand's product (alpha cutout)
   = the AD's visual
```

- Generate **people with plain backgrounds → cutouts**; swap settings and products freely. A finite asset set yields combinatorial ad visuals.
- **This is also the Ad Builder's payoff**: the composed ad's art is literally its cards' layers stacked — "a female UGC creator in the forest with this product" IS hook×visual×product rendered. The builder's "generates the visual representation" becomes a layering operation, not generation at runtime (local-first preserved: all layers are baked assets).
- Team/actor cards use the same person-layer system (a hire's portrait = person layer on a desk setting).

## 5. Art style: stylized retro cartoon, never realistic

Style target: **a specific retro cartoon style** (exact flavor TBD by the exploration batch — UPA flat, rubber-hose, mid-century ad illustration, cereal-box mascot, storybook, chunky sticker-pop…). Generated via GPT Image (OpenRouter `openai/gpt-5.4-image-2`) at AUTHOR TIME only — generations are concept/asset source material, runtime stays local-first. Consistency strategy: pick ONE style, build a prompt "style bible" string, regenerate everything through it.

## 6. Open questions

1. Identity ruling (§3): brand-as-client-character vs brand-as-self?
2. Tech tree scope: per-run unlocks vs meta-collection (pillar 3 says broaden-never-strengthen — new products must be sideways, not upward, power)?
3. How many brands at v1? (Each = audience priors + product set + art identity — content cost.)
4. Person layers and likeness: fully synthetic people only (no real-person resemblance prompts).
5. Does the player SEE the layering (builder shows layers snapping) or just the result?
