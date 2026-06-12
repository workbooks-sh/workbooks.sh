# The component library — shared primitives, one home each

Archetypes lay out sections; **components** are the primitives the archetypes
compose. The library is the design analogue of ONE Host: every surface depends on
one well-factored component instead of re-implementing it. Build the library in
Stage 1; archetypes and sections only *compose* it.

## The principle (Golden Rules 1–3)

- **DRY** — no copy-pasted button/card CSS. One definition, varied by token/prop.
- **Least code** — a variant is a modifier on the base, not a new component.
- **Componentize** — reduce duplication by increasing dependence on one good
  component, never by re-writing per consumer. If two sections style a card
  differently, that's drift — reconcile into one card with a variant, don't keep
  both.

## A starting set

| Component | Variants (via token/prop) | Notes |
|---|---|---|
| **Button** | primary / ghost / link | one base; `settle` on hover; never per-section colors |
| **Card** | flat / bordered / raised | pulls surface + hairline from canon; minimal shadow |
| **Eyebrow / label** | — | small caps or mono label above titles |
| **Title block** | h1…h3 | the two-face title pairing from the type axis |
| **Code / figure block** | code / image / diagram | the `reveal` motion; consistent frame |
| **Nav / header** | — | sticky behavior + the logo lockup |
| **Texture surface** | per archetype | the signature texture as a backing layer |
| **Cursor / agent affordance** | — | for living-runtime surfaces showing agent presence |

## Rules

- **Every component reads ONLY from canon tokens** — color, type, spacing, motion.
  A component with a hardcoded hex or px is a drift bug.
- **Minimal chrome.** Premium components are small, light, and modern — avoid big
  heavy drop-shadows and vanilla "card with shadow" defaults (the recurring note
  that overlays/chrome read amateur when too big/heavy).
- **No component-library defaults shipped raw.** If you pull in a UI kit, re-skin
  every primitive to the canon before it ships. Shipping a kit's default look is
  the single most common way a page reads as AI-generated.
- **One edit site.** Like the skills tree's symlink discipline, a component has one
  source; consumers reference it. Don't fork a component to tweak it for one
  section.

**Gate (Stage 1):** the primitives are listed, each reads from tokens, before any
section composes them. Build/verify ONE primitive to the premium bar (Stage 3)
before scaling the rest.
