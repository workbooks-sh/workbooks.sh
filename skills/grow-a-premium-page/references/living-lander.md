# Worked example — the Workbooks living-lander

This is the canon made concrete on ONE surface: the Workbooks living-lander (the
Svelte landing site composed into `workbooks.html`, deployed on Fly via the
project's own CLI/Deploy Kit). Read it to see each abstraction instantiated, then
**generalize the discipline to your brand** — don't paste these specific colors
onto an unrelated product.

## The canon, instantiated

- **Palette.** One primary: live green `#3fe081` on dark, deepened to `#149157` in
  light mode for contrast. The ONE rule, held as canon: keep the bright green, but
  **pair it with INK text, never pure white** — and **blue is demoted to a single
  tint, not a co-primary**. That single rule is what keeps every section from
  drifting into a rainbow.
- **Type.** A two-face, size-matched title pairing (serif display + Geist) with
  **Geist Mono scoped** to code/labels — never titles. Earlier iterations that put
  mono in titles or shrank the serif were explicitly rejected as not-clean. Fonts
  are fetched, not bundled.
- **Texture — the signature.** An **ASCII shader field + grid textures** drawn from
  the palette. This is the unmistakable-this-brand element; it backs content, it
  isn't wallpaper.
- **Voice.** The pitch line is **"software built in workbooks" / "workbooks in the
  wild"** — and explicitly **never "sites that run themselves"** or perpetual
  agent-management. The visual premium and the verbal register agree.

## The system, instantiated

- **Section archetypes.** The lander is built from a fixed catalog of section
  shapes — Hero, What, Make, Proof, Questions, Yours (the CTA "make it yours"
  close), plus the showcase of real self-building sites. Each is a reused layout
  contract, not a bespoke section.
- **Component library.** Shared primitives — the LogoCard (saturated background +
  subtle lighter W, inverted deliberately), Section wrapper, buttons, and an
  AgentCursor primitive that shows agent presence on a living-runtime surface — all
  reading from the canon tokens.
- **Human-only zones.** The Hero, `#examples`, and certain panels are
  human-curated; the living examples fleet (e.g. WULU, a Netflix×NYT-style AI
  curation site) populates the showcase. An autonomous agent extends the page
  WITHOUT touching these curated cores — the archetype catalog marks what's
  agent-fillable.

## Why it's the right worked example

The living-lander is a **living-runtime surface**: a page that is itself built and
extended on the Workbooks runtime, by agents, against a fixed canon — exactly the
case this skill generalizes. It shows the design discipline as the twin of the
create-runtime discipline: a fixed canon (the HOST analogue) above a hot-swappable
set of sections and components (the LOADED analogue), with agents editing only the
loaded layer and never the canon.

**Generalize, don't copy.** For your brand: derive YOUR palette/type/texture/voice
(Stage 0), name YOUR motion vocabulary and archetype catalog and component library
(Stage 1), and gate on the premium bar. The green, the ASCII shader, and the
Geist pairing are Workbooks' answers — the *method* is what transfers.
