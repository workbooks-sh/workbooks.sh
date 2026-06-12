# The section-archetype catalog — section shapes as layout contracts

A page is not a stack of bespoke sections. It is a sequence of a **small set of
section archetypes** — reusable layout *shapes*, each a contract: what slots it
has, how it lays out against the grid, how it enters. You build the catalog once
(Stage 1), then the page is assembled by choosing archetypes, not by designing
each section from scratch. This is the design analogue of routing every capability
through a known seam instead of forking code per case.

## Why archetypes (not freeform sections)

- **DRY / componentize** (Golden Rules 1 & 3): one layout home per section shape,
  reused, so spacing and rhythm stay consistent down the page.
- **Rhythm.** A page reads premium when sections share a vertical rhythm and
  alternate predictably. Freeform sections destroy rhythm.
- **Velocity.** New page = pick archetypes + fill slots. No re-deciding layout.

## A starting catalog

Adapt to the surface; most marketing/product pages need only 6–8 archetypes.

| Archetype | Job | Slots |
|---|---|---|
| **Hero** | first impression, one claim + one action | eyebrow, title, sub, primary CTA, signature texture |
| **Proof** | evidence — logos, metrics, quotes | heading, proof items (grid/row) |
| **Explainer / What** | what it is, in one read | heading, body, supporting figure/diagram |
| **Make / How** | the mechanic or steps | step items (ordered), optional code/figure |
| **Showcase** | the thing in the wild | media + caption, repeatable |
| **Q&A / Questions** | objection handling | question + answer pairs |
| **CTA / Yours** | the close — make it the reader's | heading, single action, minimal else |
| **Footer** | nav, legal, secondary links | link groups, fine print |

Each archetype is a **layout contract** — define its slots, its grid placement,
its one entrance motion (from the vocabulary), and its spacing (from the scale).
A concrete section is an *instance* of an archetype with its slots filled.

## Rules

- **A new section should map to an existing archetype.** If it genuinely doesn't,
  add a new archetype to the catalog deliberately — don't freehand a one-off.
- **One entrance motion per archetype**, reused across instances — not per
  section.
- **Reserved/human-only zones exist.** For the Workbooks lander, the hero,
  `#examples`, and certain panels are human-curated — agents don't autogenerate
  into them. When building a living-runtime surface, mark which archetypes are
  agent-fillable vs. human-only, so an autonomous agent extends the page without
  touching the curated core.
- **Pitch register matters.** Section copy must stay on the brand's claim line
  (for Workbooks: "software built in workbooks" / "workbooks in the wild" — never
  "sites that run themselves"). The archetype's copy slots inherit the voice axis.

**Gate (Stage 1):** the catalog is named, each archetype's slots/motion/spacing
written, before any section is built.
