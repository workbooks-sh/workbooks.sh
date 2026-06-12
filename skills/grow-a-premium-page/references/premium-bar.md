# The premium bar — the gate

"Premium" is not a vibe; it is a checklist a surface must pass before it ships.
This is the design twin of `mix compile` being the first gate on a runtime edit —
run it on every unit (Stage 4) and on every surface as you scale (Stage 5). A unit
that fails any item is not done; fix it before moving on.

## What "premium" concretely means

A surface reads premium when it is **coherent, restrained, and considered** —
every element traces to the canon, nothing is a default, motion is felt not
watched, and it holds together at every size. The opposite (the failure this skill
prevents): mixed colors per section, a UI kit's stock look, heavy shadows, busy
clashing animation, and a layout that breaks on mobile.

## The ship checklist

**Canon adherence**
- [ ] No color outside the palette tokens. The ONE palette rule holds (no second
      accent hue, primary paired per the rule).
- [ ] Only the two canon faces; mono scoped; titles use the size-matched pairing.
- [ ] Every gap/pad references the spacing scale — no magic numbers.
- [ ] The signature texture is present but sparing, and draws only from canon
      colors.

**Components & layout**
- [ ] Built only from library primitives; no copy-pasted/forked component CSS.
- [ ] No raw component-library default look anywhere.
- [ ] Section maps to a catalogued archetype (or the catalog was extended
      deliberately).
- [ ] Chrome is minimal — no oversized heavy drop-shadows; modern, light.

**Motion**
- [ ] Every animation is a named motion from the vocabulary (fixed easing +
      duration).
- [ ] One entrance pattern for scroll-revealed content; transition policy honored.
- [ ] `prefers-reduced-motion` fallback present on every motion.
- [ ] Transform/opacity only on animated elements; no layout-property animation.

**Responsive & a11y**
- [ ] Renders at real breakpoints (mobile + desktop), not just the design width.
- [ ] Text contrast passes against its actual background (the readable-on-X rule
      in practice).
- [ ] Tap targets, focus states, and semantic structure intact.

**Voice**
- [ ] Copy is on the brand register and claim line; no off-pitch or
      catalog-label/SKU-decoration copy.

## How to run it

- **Tightest tier first.** Preview locally — the project's frontend dev server for
  a Workbooks surface, or open the built file for a standalone page. Never await a
  deploy to learn if it looks right.
- **Per unit, then per surface.** Pass the unit in Stage 4 before scaling; re-run
  per section in Stage 5 to catch drift early.
- **Drift is the recurring failure** (Golden Rule 4): when an item fails because a
  section introduced a one-off, fix by aligning to the system, not by patching the
  section.

A surface that passes every box is premium. Until then it isn't shippable.
