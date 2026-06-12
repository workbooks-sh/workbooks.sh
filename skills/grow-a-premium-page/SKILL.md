---
name: grow-a-premium-page
description: Design and build a premium web page or surface — landing page, marketing site, product page, console, or any living-runtime UI — to a high design bar instead of vibe-coding chrome. The design twin of create-runtime — STAGED, anti-vibe-code — eliciting a DESIGN CANON before any markup. Establishes a design canon (palette, type, spacing, texture), a motion vocabulary, a section-archetype catalog, and a reusable component library, runs a staged design process, and gates on a premium bar. Use whenever an agent is asked to make a page/site "look good," "feel premium," "redesign," "polish the UI," build a landing page or hero, or set a design system — read it BEFORE writing CSS, because the failure mode is shipping generic component-library defaults. GENERAL, not tied to any one site.
---

# Grow a premium page (staged — anti-vibe-code)

Design work is canon work. A page is the LOADED layer of a brand: every section,
component, and motion either compounds one coherent system or fragments it. The
failure mode is **vibe-coding chrome** — reaching for a component library's
defaults, sprinkling drop-shadows, picking a color per section — which yields a
page that looks like every other AI-built page. So this skill is **staged**: each
stage is a gate. **Do not skip forward.** Writing CSS before the canon is set and
the design is checked against the premium bar is the failure this skill prevents.

This is the design twin of `create-runtime`. There, you elicit a *capability* and
route it through ONE Host before touching engine code. Here, you elicit a *design
canon* and compose every surface from ONE system before touching markup.

> If you are tweaking one existing component or fixing a tracked visual bug, this
> staged process is overkill — make the surgical edit, but still respect the
> canon (§ design-canon) and the premium bar (§ premium-bar). This skill is for
> *new* surfaces and for setting/raising a design system.

## Read first (before Stage 0)

- `references/design-canon.md` — the five canon axes (palette, type, spacing,
  texture, voice) and how to fix them as tokens, not per-section guesses.
- `references/premium-bar.md` — the gate. What "premium" concretely means and the
  checklist a surface must pass before it ships.
- `references/living-lander.md` — the **worked example**: how the Workbooks
  living-lander instantiated every axis. Read it to see the abstractions made
  concrete — then generalize, don't copy its specific colors onto an unrelated
  brand.

## The stages (each is a gate)

### Stage 0 — ELICIT the canon (no markup)
Pull the brand's ACTUAL design canon and write it down as tokens. Do not write
markup in this stage. Answer, explicitly, each axis (§ design-canon):
- **Palette** — one primary, its readable-on-X pairings, neutrals, and the ONE
  rule that prevents per-section color drift. Name the collision to avoid.
- **Type** — the title face + the body/UI face (usually two, size-matched), the
  type scale, and where (if anywhere) mono appears.
- **Spacing & grid** — an explicit spacing scale and the layout grid; nothing
  ad-hoc.
- **Texture** — the signature non-flat element (shader, grid, grain, gradient
  field) that makes the surface unmistakably this brand, used sparingly.
- **Voice** — the copy register, so visual and verbal canon agree.

If a brand site or existing artifact exists, **derive the canon from it** rather
than inventing — the same discipline as deriving a brand book from a URL.

**GATE:** the canon is written as tokens (CSS custom properties or equivalent)
before Stage 1. If you cannot state the ONE color rule, you are not ready to
design.

### Stage 1 — DESIGN the system (no production markup)
With the canon fixed, define the two reusable layers (don't yet build pages):
- **Motion vocabulary** (`references/motion-vocabulary.md`) — a small, named set
  of motions (e.g. *rise-in*, *reveal*, *settle*) with fixed easings and
  durations. Motion is a vocabulary, not a per-element decision. Decide the
  transition policy up front (e.g. hard cuts vs. fades) so it can't drift.
- **Section-archetype catalog** (`references/section-archetypes.md`) — the small
  set of section *shapes* the page is built from (hero, proof, explainer,
  Q&A, CTA, …). Each archetype is a layout contract, reused, not re-invented per
  section.
- **Component library** (`references/component-library.md`) — the shared
  primitives (button, card, eyebrow, code/figure block, nav) that every
  archetype composes. One home per component — DRY, componentize. This is the
  design analogue of routing every capability through ONE Host.

Check the design against canon: does any section introduce a color, font, or
motion not in the system? → that's drift; fold it back in or extend the system
deliberately, never patch around it.

**GATE:** motion vocabulary + archetype catalog + component library are named and
written down before any production markup.

### Stage 2 — FILE
Open a **bd** epic + sub-issues — one issue per archetype/section or per
component (platform ledger; see `working-with-tasks`; `.beads` is local-only,
never git).

**GATE:** issues exist (`bd show <epic>`).

### Stage 3 — BUILD the smallest premium unit
Build ONE component or ONE section archetype end-to-end — to the full premium bar
— before scaling out. Prefer **least code**: lean on the tokens and the component
library; delete duplicated CSS rather than adding variants. A half-built page at
the premium bar beats a whole page at the component-library default.

### Stage 4 — VERIFY against the premium bar (tightest tier first)
Run the `references/premium-bar.md` checklist on the unit you built:
- Renders at the real breakpoints (mobile + desktop), not just one width.
- Motion uses only the named vocabulary; respects `prefers-reduced-motion`.
- No stray color/font/shadow outside the canon; contrast passes.
- Preview it locally — never await a deploy to learn if it looks right. For a
  Workbooks surface that's the project's local preview (e.g. the frontend dev
  server); for a standalone page, open the built file.

Iterate on this one unit until it passes, THEN scale the pattern to the rest.

### Stage 5 — SCALE & guard against drift
Apply the proven archetype/component across the remaining sections. As you go,
re-run the premium bar per surface. The recurring risk is **drift** — a new
section quietly adding a one-off color or motion. When you catch it, fix by
aligning to the system, not by patching the section (Golden Rule 4).

## References
- `references/design-canon.md` — the five canon axes; fix them as tokens.
- `references/motion-vocabulary.md` — naming a small motion set; easing/duration
  discipline; the transition policy.
- `references/section-archetypes.md` — the catalog of section shapes as layout
  contracts.
- `references/component-library.md` — shared primitives, one home each (DRY /
  componentize).
- `references/premium-bar.md` — the gate: what premium means + the ship checklist.
- `references/living-lander.md` — the Workbooks living-lander as the worked
  example of every axis (read for the pattern, generalize for your brand).
