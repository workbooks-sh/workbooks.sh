# Tecovas Brand Book V2 — 42-Section Expansion Design

I now have everything I need: real ad media URLs, real catalog image URLs (702 products carry them), the analysis prose families, the firmographics gap, the social numbers, and the architecture/capabilities findings. I'll write the design doc.

Note: One discrepancy worth flagging — the audience analysis cites IG follower count 796,201, but the live deck render and inventory both treat that as verified. I'll use the inventory numbers throughout.

---

# Tecovas Brand Book — Full Expansion Design & Build Plan (13 → 42 sections)

## 0. The load-bearing fact (read this first)

The Tecovas deck is **authored by the strategist LLM writing free-form HTML directly** — not by a deterministic in-repo generator. `presentation-shell.ts` is the *seed-brand* path and emits a *different* shell; it does NOT produce this deck. So expansion is a **skills + CSS-shell + prompt-cap** change, edited in the four `.org` skill files (in BOTH `substrates/brandnana/profile/skills/` and `services/brandnana-agent/profile/Engine/skills/`) plus the engine-side `compose-deck-prompt.txt` at `/opt/brandnana-profile/` — NOT a code-generator change. The two bugs you patched (empty `.tall-grid`, truncated `.ad-brief`) were content-population failures in the LLM write step; the fix is a **required-children contract + a stable component library**, so the visual gate has nothing to catch.

All images embed as **remote CDN `<img src>` URLs** (`https://api.brandnana.net/assets/<sha>.<ext>` and `.../concept-images/<slug>/<ref>.png`), copying the `slideHomepage()` pattern (`src=…  loading=lazy  onerror=fallback`). **Never data-URI** harvested media — the deck is already 617KB with zero images; inlining 4,687 webp would balloon it to MBs and choke `render-slides`. Reserve base64 strictly for the make-image upload-failed fallback.

---

## PART 1 — THE 42-SECTION OUTLINE (grouped into 11 acts)

Every section cites its EXACT source. Sections marked **[NEEDS HARVEST]** depend on data that is currently missing/empty and must be re-pulled (see Part 3b). Sections marked **[NEEDS VISION]** require running creative-vision over real ad media (HOOK/MOOD/CTA are blank on all 20 ad rows today).

### ACT I — Identity & Story (sections 1–4)

**01. Cover** — Brand wordmark + tagline + credit line.
Source: `brand.org` logo SVG (`…827469…c8ac09c.svg`), TAGLINE "Forever West.", palette `#040404`/`#b1624c`/`#f9f1e9`. *(Existing — keep, refine.)*

**02. The Thesis** — One-paragraph strategic thesis: "The first digitally-native Western brand, mass-premium, Hero-Craftsman." 3 headline stats (1.03M social reach, 1,358 products, $0–$2,795 range).
Source: `brand.org` Voice paragraph; audience analysis (`1,027,898` reach); catalog inventory (1,358 products, price band counts).

**03. Brand Story / Origin** — Austin TX, founded 2015, first digitally-native Western brand, DTC + brick-and-mortar + wholesale.
Source: `brand.org` Voice paragraph verbatim. *(Founded-year is prose-only; the firmographics block at §35 will make it structured — see [NEEDS HARVEST].)*

**04. The "Forever West." Promise** — Big type treatment of the tagline as the spine; how it carries IG/TT/Twitter bios + the "Forever West" YouTube film (39,442 views).
Source: voice analysis `:insight:voice:`; `brand.org` TAGLINE.

### ACT II — Strategy & Positioning (sections 5–9)

**05. Positioning Statement** — Premium-Western-American on three repeatable claims: named heritage material + stated construction + stated place-of-make.
Source: positioning analysis `:insight:positioning:` (GROUNDS: the-cartwright, the-stallion, the-dean, the-dillon, the-marshall).

**06. The Three Proof Claims** (3-col card) — (1) Named materials (American alligator, regenerative bison, Nile crocodile, full-quill ostrich); (2) "¾ Goodyear welt" construction; (3) "Handmade in León, Mexico." (appears 20× in catalog body).
Source: positioning analysis (the three repeatable claims, verbatim counts).

**07. Messaging Pillars** (4 `.pillar` cards — *this is the slide that shipped EMPTY; required-children contract guarantees ≥4 children*) — West-as-Identity / Craft / Place-of-Make / Store-Ritual, each with its YouTube anchor (3.49M "How We Make Them", 272K "Welcome to Tecovas").
Source: messaging analysis `:insight:messaging-pillars:`.

**08. Whitespace / Opportunity** — The unclaimed service-guarantee gap ("Lifetime resoling. Free re-crafting."), grounded against the one negative FB service comment.
Source: positioning analysis `:insight:whitespace:` (Sarah Booher FB comment).

**09. Competitive Frame** — Where Tecovas sits vs. resort-boot makers / custom bootmakers; the service-promise is unclaimed by competitors.
Source: positioning `:insight:whitespace:` (competitor mention). *Note: no dedicated competitor harvest exists — prose-only unless a `competitors` analysis family is added (Part 3b).*

### ACT III — Audience & Personas (sections 10–14)

**10. The Audience** — Mass-premium Instagram-anchored Western buyer; reach breakdown (IG 77.5% / TT 19.8% / YT 2.7% / TW <1%).
Source: audience analysis `:insight:audience:`; social follower counts.

**11. Reach by Platform** (stat block / bar viz, pure-CSS) — IG 796,201 (verified) · TikTok 203,700 (verified) · YouTube 28,000 · Twitter 9,997 · **Facebook [NEEDS HARVEST: needs_key]** · **LinkedIn [NEEDS HARVEST: needs_key]**.
Source: `social/*.org`. Flag FB/LinkedIn as "needs re-harvest with provider key."

**12. Persona — The Newcomer** — IG/TikTok first-time boot buyer; anchored on The Cartwright ($365) + The Annie. Platform signature: 3.79M-play TikTok Black Friday giveaway, 205K Kacey Musgraves anchor.
Source: audience `:insight:personas:` persona (1).

**13. Persona — The Everyday Texan** — $300–500 boot core; anchored on The Dean (14 SKUs) + The Earl (13 SKUs); 272K "Welcome to Tecovas" store-ritual video.
Source: audience `:insight:personas:` persona (2).

**14. Persona — The Connoisseur** — $1,000+ exotic buyer; anchored on The Stallion ($2,795), The Marshall ($1,995), The Bowie ($1,495); 3.49M "How We Make Them" film.
Source: audience `:insight:personas:` persona (3).

### ACT IV — Visual Identity (sections 15–20)

**15. Logo System** — Logo SVG + clear-space + lockups (pure CSS).
Source: `brand.org` Logo block.

**16. Primary Palette** (`.palette-grid`) — `#040404` "Armor Wash" / `#b1624c` "Clay Red" / `#f9f1e9` "Baby Blossom".
Source: `brand.org` primary palette; voice/tone analysis (token names).

**17. Extended Palette** (`.palette-grid`, 12 swatches) — full 12-token swatch incl. moss `#555f45`, olive `#696f42`, slate `#69757c`; flag `#3b82f6` as the off-brand focus-ring (do-NOT-use).
Source: `brand.org` extended palette; dos-donts `:insight:dos-donts:`.

**18. Typography** (`.type-grid`/`.type-card`) — `mundial` (body sans) + `lorimer-no-2` (display serif) as "typography-as-genre-cue."
Source: `brand.org` Typography; voice/tone analysis.

**19. Color in Practice** (image-with-callouts) — Homepage screenshot annotated with palette swatches pulled from the live page.
Source: `brand.org` Homepage screenshot PNG (`…aa054ab8…905c.png`).

**20. Tone & Texture** (mood-board grid, NEW type) — leather-and-saddle warm-earth tone board assembled from logo + palette swatches + 4–6 hero catalog product crops.
Source: tone analysis `:insight:tone:` + curated catalog `.webp` images (assembled, not pre-existing).

### ACT V — Product & Catalog (sections 21–26)

**21. Catalog at a Glance** (stat block) — 1,358 products · 43 categories · $0–$2,795 (avg $176) · 1,273 in-stock / 85 OOS · price bands (0–100: 678, 100–200: 305, 200–300: 145, 300–400: 121, 400+: 109).
Source: catalog inventory aggregates.

**22. Price Architecture** (pure-CSS band chart) — The $0–100 tail (tees/socks/leather), the $300–500 boot core (median ~$375), the $1,000+ exotic ceiling (6 SKUs, peak $2,795).
Source: catalog price-band counts; audience analysis price structure.

**23. Hero Product — The Stallion** (image-with-callouts, NEW type) — $2,795 American alligator; "Legendary by Design." Big product spread.
Source: catalog row `the-stallion-x-tecovas-boot` ($2,795); archetype analysis copy. *Parent SKU has empty IMAGES — pull a child-variant image (12 imgs exist) or [NEEDS HARVEST] re-map parent→variant images.*

**24. Hero Product — The Marshall** (image-with-callouts) — $1,995 Nile crocodile; "the finest boot we've ever made." (17 imgs).
Source: catalog `the-marshall`; archetype analysis.

**25. The Boot Range** (image-grid / product wall, NEW type) — 9-up grid: Cartwright, Dean, Dillon, Earl, Annie, Bowie, Doc, Wyatt, William, drawn from real `.webp` URLs.
Source: catalog rows for the named hero boots; 702 products carry image URLs (4,590 webp / 97 jpg).

**26. Beyond Boots** (image-grid) — Apparel (159), Accessories (97), Belts (23), Outerwear (22), Hats (17); same-bison-leather belt bundling story.
Source: catalog collection counts; bison-belt copy ("same rugged bison leather as our boots").

### ACT VI — Ad Creative + Vision Analysis (sections 27–32)

> All sections here are **[NEEDS VISION]** — HOOK/MOOD/CTA are blank on all 20 ad rows. Run creative-vision (`minimax/minimax-m3` via OpenRouter) over the real mirrored ad media to populate the rich `CreativeAnalysis` schema (hook, subject_focus, products_visible, people_count, setting, text_overlays, cta_visible, mood, palette, summary).

**27. The Ad Footprint** — Honest constraint card: 20 ads, all Meta-only, 19 stills + 1 video; 17 on-property, 3 off-property cross-listings (shoebacca, bravewildernessnetwork, page 100090571584781) explicitly excluded.
Source: ads-ideas `:insight:ad-ideas:` honest-constraint; `ads.org`.

**28. Ad Creative — Still #1** (ad-analysis card, NEW type) — real ad image (`…74db85e1…f78896.jpg`, AD_ID 958080217212042) + vision analysis (hook/mood/subject_focus/palette/summary).
Source: `ads.org` AD_ID 958080217212042 media; creative-vision output **[NEEDS VISION]**.

**29. Ad Creative — Still #2** (ad-analysis card) — AD_ID 2018803495668632 (`…91ee84a3…a26258.jpg`) + vision analysis.
Source: `ads.org`; creative-vision **[NEEDS VISION]**.

**30. Ad Creative — Still #3** (ad-analysis card) — AD_ID 984819150795943 (`…c8c92f7f…a870d.jpg`) + vision analysis.
Source: `ads.org`; creative-vision **[NEEDS VISION]**.

**31. Ad Video — "León in motion"** (video-still + analysis, NEW type) — the lone .mp4 (AD_ID 1288871850038977, `…0361fe2f…c93c712.mp4`); render the poster frame as still + minimax video analysis (pacing, key_moments, falls back to poster-frame analysis if inline-video fails).
Source: `ads.org` the single video row; creative-vision video path **[NEEDS VISION]**.

**32. Creative Patterns** (cross-ad synthesis) — What the 19 stills share (subject_focus, palette adherence to warm-earth, CTA presence) once vision runs across all of them, pooled concurrency ~8–12.
Source: aggregated `CreativeAnalysis[]` across all 20 ads **[NEEDS VISION]**.

### ACT VII — Social & Lifestyle (sections 33–35)

**33. Content Themes** — YouTube content map: the 10 top titles ("Love Letter to Texas", "True West", "How We Make Them", "Welcome to Tecovas", "Tecovas Work", "You're on in Five Featuring Sierra Ferrell").
Source: `social/youtube.org` 10 titles (thumbnails **[NEEDS HARVEST: needs_mirror]** — run with `--mirror`).

**34. Voices from the Audience** (`.testimonial-grid`) — Honest read: 1 negative + fan UGC + 1 artist quote. Wendy Castillo-Garza ("Pick me!"), Allie Aston ("Can I intern??"), Sarah Booher (service complaint), Sierra Ferrell artist quote ("stagewear is more than style — it's armor").
Source: testimonials analysis `:insight:testimonials:`.

**35. Lifestyle / Editorial** (image-grid, NEW type) — On-model and in-context imagery. **[NEEDS HARVEST]**: no distinct lifestyle asset exists; the 12-item "Lifestyle" collection is the closest. Assemble from the richest catalog on-model crops, OR flag: "lifestyle/editorial imagery must be re-harvested (no editorial URLs captured)."
Source: catalog "Lifestyle" collection; flag gap.

### ACT VIII — Mood Boards (sections 36–37)

**36. Mood Board — "Forever West"** (mood-board grid, NEW type) — 9–12 image tile board mixing hero boots + ad stills + logo + palette, expressing the brand world.
Source: assembled from catalog `.webp` + `ads.org` stills + logo SVG (no pre-existing mood-board image set — assembled per architecture rec).

**37. Mood Board — "León Craft"** (mood-board grid) — craft-focused board: construction close-ups + leather-texture crops + the "Handmade in León" line.
Source: assembled from catalog detail-image crops; positioning craft lexicon.

### ACT IX — Firmographics & Market (sections 38–39)

**38. Firmographics** (stat/firmographics block, NEW type) — **[NEEDS HARVEST — CRITICAL]**: founded year, HQ city/country, employee range/count, revenue band, industry + NAICS/SIC, structured socials map.
Source: **currently MISSING/errored** — `harvest-provenance.org` line 50 "firmographics null — provider keyless (record needs_key, not green)"; `brand.org` FOUNDED/HQ/CATEGORY all empty; social-handles render "[object Object]" ×6. **Must run `brand company tecovas.com` (The Companies API, `THE_COMPANIES_API_KEY`) + Valyu backfill.** Until then, render prose-only ("Austin, founded 2015") with an explicit `needs_key` badge so the visual gate flags it honestly.

**39. Market & Channels** — DTC (tecovas.com) + brick-and-mortar store network + select wholesale; the in-store ritual as channel differentiator.
Source: `brand.org` Voice paragraph (channel mix); messaging Pillar 4 (store ritual).

### ACT X — Campaign Directions (sections 40–41)

**40. Five Ad Concepts** (ad-brief cards — *this is the section that TRUNCATED; required-full-copy contract guarantees no mid-sentence cuts*) — (1) Cartwright 50-Year Promise carousel; (2) True West still + quote; (3) "León in 60 seconds" video; (4) Stallion "Legendary by Design"; (5) "Howdy from Austin" UGC.
Source: ads-ideas `:insight:ad-ideas:` five concepts (each grounded in a real product/social hook).

**41. Headline & Subhead Library** — 5 headline patterns + 6 subhead lines, each lifted verbatim from real product/social copy ("Forever West. Built in León.", "Looks as good in 50 years as it does today.", "Goodyear-welted. Leather-soled. Built to be re-soled.").
Source: copy analysis `:insight:copy-ideas:` (both nodes).

### ACT XI — Methodology (section 42)

**42. Methodology & Provenance** — How the book was built: capture timeline, sources, what's grounded vs. flagged. Honest disclosure of the `needs_key` gaps (firmographics, FB/LinkedIn followers, social thumbnails) and the vision-analysis pass over ad media.
Source: `harvest-provenance.org` capture log; the `needs_key`/`needs_mirror` flags across the substrate.

**Section count: 42.** Maps 1:1 to grounded `:insight:` families + identity/catalog/social/ad data, preserving the audit contract.

---

## PART 2 — NEW SECTION TYPES THE GENERATOR MUST SUPPORT

These become **stable, documented CSS components** added to the deck's `<style>` shell, each with a **REQUIRED-CHILDREN contract** in `publish-workbook.org` so the LLM never ships an empty or truncated container (the exact bug class you patched). Existing components to keep: `card`, `grid-2`, `two-col`, `palette-grid`, `type-card`, `ad-grid`, `testimonial-grid`, `pillar`.

| # | New type | CSS class | Required children (contract) | Image embed |
|---|----------|-----------|------------------------------|-------------|
| 1 | **Ad-analysis card** | `.creative-card` → `.creative-media` (img) + `.vision-note` | MUST contain 1 `<img src=remote>` + a `.vision-note` with ≥4 fields (hook, mood, subject_focus, palette swatches, summary). Empty vision-note = invalid. | remote `<img src=ads.org MEDIA_URL>` loading=lazy onerror=fallback |
| 2 | **Image-grid / mood-board** | `.moodboard-grid` → N× `.moodboard-tile` (img) | MUST contain ≥6 `.moodboard-tile`, each with a non-empty `<img>`. No empty tiles. | remote `<img>` per tile from catalog `.webp` / ad stills / logo |
| 3 | **Video-still + analysis** | `.video-still` → poster `<img>` + `.play-badge` + `.analysis-caption` | MUST contain a poster `<img>` (the .mp4's frame), a play affordance, and `.analysis-caption` with pacing + key_moments + summary. | remote poster `<img>`; never embed the .mp4 itself in the deck |
| 4 | **Stat / firmographics block** | `.firmographics` → `.stat-block` ×N | MUST contain ≥1 `.stat-block`; each has label+value. If `needs_key`, render `.stat-block.needs-key` placeholders (NOT empty) so the gate flags honestly. | no image (data block) |
| 5 | **Image-with-callouts** | `.callout-image` → `<img>` + `.callout` ×N (absolutely positioned pins) | MUST contain the `<img>` + ≥2 `.callout` pins. | remote `<img>` (homepage PNG or hero product webp) |
| 6 | **Stat bar / reach viz** | `.stat-bars` → `.bar` ×N | MUST contain one `.bar` per platform with a width-% style. | pure CSS, no image |

**Image embedding rule (per architecture finding):** ALL media = **remote CDN URLs**, copying `slideHomepage()`:
```html
<img src="https://api.brandnana.net/assets/<sha>.webp" loading="lazy"
     onerror="this.closest('.moodboard-tile').classList.add('img-fail')">
```
- **Harvested media** (ad stills, ad video poster, product images, logo, homepage) → reference the R2 URLs the harvester already stored (`ads.org` MEDIA_URL, catalog `:IMAGES:`, `brand.org` logo/screenshot).
- **Generated media** (mood-board fills if synthesized, concept imagery) → `make-image.org` → POST `/v1/asset/upload` → permanent `concept-images/<slug>/<ref>.png`.
- **Data-URIs / inline base64**: FORBIDDEN in the deck body. Reserved strictly for the make-image upload-failed fallback. Rationale: deck is 617KB with zero images; ~40 remote images keeps the HTML small and lets `render-slides` lazy-load. Inlining would push it to multi-MB and choke the render gate.
- **Media compression**: the mirror path does NOT compress (raw bytes, sha256 dedup). Webp catalog images are already small; the only heavy asset is the .mp4 — never embedded, only its poster frame.

---

## PART 3 — THE BUILD PLAN (3 stages)

### Stage A — Generator / template changes (LOCAL skill + CSS edits; fix bugs so the gate has nothing to catch)

Edit the four skill `.org` files in **BOTH** locations (keep in sync):
`substrates/brandnana/profile/skills/` AND `services/brandnana-agent/profile/Engine/skills/` → `{compose-deck, publish-workbook, write-analysis, make-image}.org`. Plus the engine-side `compose-deck-prompt.txt` at `/opt/brandnana-profile/` (NOT in repo — edit on the worker/agent image).

1. **Add the shared CSS component library** to the deck `<style>` shell: the 6 new components above + document each in `publish-workbook.org` with its REQUIRED-CHILDREN contract. This is what structurally prevents the empty-`.tall-grid` bug — a container with zero required children is now an invalid emit.
2. **Add a "no-empty / no-truncate" write contract** to `publish-workbook.org`: every container node MUST get its minimum children; every copy field MUST be complete (no mid-sentence cuts — the `.ad-brief` "…from the 3" → "…3.49M-view YouTube film" bug). The per-section parallel LLM write step validates child-count before assemble.
3. **Raise the caps**: `compose-deck.org:135` caps **8 nodes / 5 images → bump to ~44 nodes / ~40 images**. `book.ts:785 --max-slides default 60` already covers 42 (confirm). `render-slides.ts` `max_slides` default 60 — OK.
4. **Expand the `:insight:` families** in `write-analysis.org` from ~11 to cover the new section types so each new slide still maps 1:1 to a grounded insight: add `ad-creative-vision` (per-ad), `firmographics`, `lifestyle`, `mood-board`, `catalog-stats`, `competitors`, `content-themes`. Preserves the audit/grounding contract.
5. **Fix the two known bugs at the contract level** (not just patch the HTML): §07 messaging `.tall-grid` must emit 4 `.pillar`; §40 ad-briefs must emit full untruncated copy. With the contracts in place these can't recur.

*All of Stage A is local/engine-side prompt+CSS editing — no app code change except optionally confirming `render-slides.ts`/`serve.ts` handle 42 slides.*

### Stage B — Data / analysis pipeline (re-pull substrate, run vision, pull firmographics)

This is where the missing data gets filled. Two wiring changes + several re-harvests:

1. **Per-ad visual analysis [the big one].** In `harvest.ts harvestAds()`, STOP analyzing `page_profile_picture_url` (the advertiser profile pic, the weak current path). Instead:
   - Re-pull ads with media: `ads search tecovas --brand tecovas.com --source meta --mirror` → populates `ad_media(ad_id, kind, url:R2, poster_url)` via the `MEDIA_URL_KEYS` extractor (lift `ads.ts:94–132` into a shared module).
   - Run the **rich** creative-vision over the **mirrored R2 url** (not the profile pic), using the full `CreativeAnalysis` schema. Image → `minimax/minimax-m3` image part; video (the 1 .mp4) → `kind:'video'` + `poster_url` so the poster-fallback guarantees an analysis. Pool concurrency ~8–12.
   - Standalone agent alternative (no server change): `ads search … --mirror`, then per `ad_media` row `creative analyze --url <r2-url> --kind image --context <body/cta>` (or batch `--file` JSON `--concurrency 8`). Needs `OPENROUTER_API_KEY`.
   - Emit `{creative_r2, analysis}` into `BrandSubstrate.ads.creativeAnalysis`. This populates the blank HOOK/MOOD/CTA fields that block sections 28–32.
2. **Firmographics [CRITICAL gap].** The CLI subcommand `brand company` is declared in schema (`verbs.ts:171`) but NOT implemented in `apps/cli/src/commands/brand.ts` — **implement it** calling `GET /brand/:domain/company`. Set `THE_COMPANIES_API_KEY` (literal token, Basic auth). Run with `--backfill` → Valyu fills null founded/HQ/employees/revenue. The server book pipeline already maps `company` → LEGAL_NAME/FOUNDED/HQ/CATEGORY/TAGLINE (`substrate.ts`) — this unblocks §38 and structures §03/§11 socials.
3. **Re-mirror social thumbnails** for §33: `--mirror` on the YouTube/social pull to get the 10 withheld thumbnail URLs. Fill FB/LinkedIn follower counts (currently `needs_key`) for §11.
4. **Expand analysis files** to emit the new `:insight:` families (Stage A #4): write `ad-creative-vision`, `firmographics`, `lifestyle`, `mood-board`, `catalog-stats`, `content-themes`, `competitors` analyses grounded in the now-enriched substrate.
5. **Map parent→variant images** for hero product spreads (§23–25): parent SKUs have empty `:IMAGES:`; pull the child-variant `.webp` URLs (Stallion has 12, Marshall 17, William 14) for the big spreads.

*What needs the engine/sandbox vs. local:* The full server re-harvest (`harvest.ts` changes, substrate regeneration) runs on the **Fly.io worker / engine image**. The standalone CLI path (`ads search --mirror`, `creative analyze`, `brand company`, `mirror images`, `book render-slides`) can be driven **locally** by an agent with the right keys (`OPENROUTER_API_KEY` for vision; `BRANDNANA_API_KEY` for everything else; `THE_COMPANIES_API_KEY` + `VALYU_API_KEY` server-side for firmographics).

### Stage C — Compose → publish → render → visual-review → fix loop

1. **Compose**: `compose-deck.org` produces a 44-node `composition.org` outline, one node per grounded `:insight:`, with the new section ANGLES (ad-creative card, mood-board, firmographics, video-still). Caps already raised.
2. **Publish**: `publish-workbook.org` runs per-section parallel LLM writes (each enforcing its required-children + full-copy contract) → assembles the single HTML with remote `<img>` embeds → `book publish tecovas <html-file>` uploads verbatim to R2 `/books/tecovas.html`.
3. **Render ALL 42 slides**: `book render-slides tecovas --max-slides 60` → per-slide PNGs to R2.
4. **Visual-review gate**: each slide PNG → `minimax-m3` vision check for empty/overflow/off-brand/illegible **AND specifically broken/missing `<img>`** (add this to the vision context — it's the check that should have caught both your bugs). Self-correct loop, cap 3 passes. Optionally feed each rendered slide PNG back through `creative analyze --url <png>` to verify ad embeds + firmographics actually rendered.
5. **Fix loop**: any flagged slide → re-write that section only (the parallel write step is per-section) → re-publish → re-render the affected slides.

### Biggest risks (call-outs)

- **Deck size with embedded media** — MITIGATED by remote-URL-only policy + `loading=lazy`. ~40 remote images keeps HTML near the current 617KB. The .mp4 is NEVER embedded (poster only). DO NOT let the LLM inline base64.
- **render-slides on 42 slides** — 42 slides × lazy-loaded remote images: the renderer must wait for `<img>` load before screenshotting, or stills come back blank. Confirm the render path awaits image-load (or add an explicit wait), and that `--max-slides 60` ≥ 42. Risk: a slow/404 CDN image → blank slide; the `onerror` fallback + the vision "broken-img" check are the safety net.
- **Vision cost** — 20 ads × creative-vision + 42 slides × visual-review × up to 3 passes = ~100+ minimax-m3 vision calls. Pool concurrency (8–12) for throughput; cap the self-correct loop at 3; only re-vision *changed* slides on a fix pass (not the whole deck).
- **Firmographics may still come back `needs_key`** — if `THE_COMPANIES_API_KEY` is unset and Valyu can't backfill, §38 must render `needs_key` placeholders (not empty), and §42 must disclose the gap. Don't ship an empty firmographics block — that's the bug class again.
- **Ad media off-property contamination** — 3 of 20 ads are non-Tecovas cross-listings (shoebacca, bravewildernessnetwork, page 100090571584781). The ad-creative sections (28–32) must filter to the 17 on-property (`facebook.com/tecovas/`) rows only.
- **Skill drift** — the skill `.org` files exist in TWO locations + the engine-side prompt is NOT in-repo. Edit all three; a partial edit silently reverts behavior on the worker.

---

**Key file paths (all absolute):**
- Skills to edit (both copies): `/Users/shinyobjectz/Apps/workbooks/substrates/brandnana/profile/skills/{compose-deck,publish-workbook,write-analysis,make-image}.org` AND `/Users/shinyobjectz/Apps/workbooks/services/brandnana-agent/profile/Engine/skills/` (same four)
- Engine-side prompt (NOT in repo, edit on worker image): `/opt/brandnana-profile/compose-deck-prompt.txt`
- App code to confirm (not change): `/Users/shinyobjectz/Apps/workbooks/projects/brandnana/apps/api/src/book/render-slides.ts`, `/Users/shinyobjectz/Apps/workbooks/projects/brandnana/apps/cli/src/commands/book.ts`
- App code to change: `/Users/shinyobjectz/Apps/workbooks/projects/brandnana/apps/api/src/book/harvest.ts` (`harvestAds` → vision over real ad media), `/Users/shinyobjectz/Apps/workbooks/projects/brandnana/apps/cli/src/commands/brand.ts` (add `company` subcommand)
- Data sources (decoded): `/tmp/tecovas-src/*.org` (19 files), `/tmp/tecovas-bundle.json`
- Live deck + your fix: `/tmp/tecovas-deck/template.html` (orig 13-section), `/tmp/tecovas-deck/deck-fixed.html` (patched)