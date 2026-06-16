# design-gate — the taste gate (Waldo: PASS this before you ship any section)

This is the taste analog of the honesty discipline. The AUDIT run keeps you
HONEST (no fake metrics, no praise, no sprawl). This gate keeps you on the
PREMIUM BAR (depth, restraint, one idea, motion that means life, green is
sacred, every section earns its place). A section that is honest but generic
still FAILS. Run this gate as the last step of EVERY ADD run, before you commit,
and again as a SECOND PASS in every AUDIT run. It is not advisory. A section
that does not PASS does not ship — you fix it or you cut it.

The bar is LIVING MACHINE (see design.md / the direction): the page is one
living organism that authors itself — bioluminescent deep-water atmosphere,
generative flow-field art, the quiet luxury of a high-end terminal, film-grain
cinema. Premium = DEPTH · RESTRAINT · ALIVENESS. Coherent, never templated,
never generic dark-SaaS.

## HOW TO RUN THE GATE (the procedure)

  Two passes. You play both roles. Do not skip the second — the critic is where
  taste actually gets enforced; the self-score is where you talk yourself out of
  shipping the obvious template.

  1. PASS A — self-score. Open the section you built (the partial + its motion +
     where it sits in the band). Score it against the six bars below, 0-2 each
     (0 absent / 1 present-but-weak / 2 fully met). Write the six scores and a
     one-line justification PER bar into the run's plan.org `* log` entry. Sum.

  2. PASS B — adversarial critic. Now ATTACK it. Re-read the section as a hostile
     second-pass reviewer whose only job is to catch the template hiding inside.
     Walk every REJECT trigger below in order and answer YES/NO out loud (in the
     log). A single YES on ANY reject trigger is an automatic FAIL regardless of
     the score — triggers are not points, they are tripwires.

  3. VERDICT.
     - any reject trigger fired → FAIL.
     - score < 9 / 12 → FAIL.
     - any single bar scored 0 → FAIL (a zero on one axis sinks the whole thing;
       a section can't buy its way past a dead axis with points elsewhere).
     - otherwise → PASS.

  4. ON FAIL: do not ship. Either (a) fix the specific failing bar/trigger and
     re-run the WHOLE gate from PASS A, or (b) cut the section — "earns its
     place or it does not ship" is literal. Never weaken the gate to pass the
     section; that is the taste equivalent of inventing a metric. If two
     consecutive fixes still FAIL, the idea is wrong, not the execution — cut it
     and write the honest "no change" / redesign note in the log.

  5. ON PASS: paste the scoreline into the commit body, e.g.
     `gate: depth 2 · restraint 2 · one-idea 2 · motion 1 · green 2 · earns 2 = 11/12, 0 triggers`.
     The timeline shows it; a future audit can see the section was gated and how.

## THE SIX BARS (PASS A — score each 0/1/2)

  Each bar is the premium-bar line stated as a testable question. Score 2 only
  if you can point at the specific thing that earns it.

  1. DEPTH over flat.
     Does the section have real layered depth — atmosphere/fog, translucent
     glass with inner light, directional light + specular edges, grain, vignette,
     parallax — rather than flat fills and hard 1px borders?
     · 0 = flat panels, bordered cards, solid backgrounds.
     · 2 = at least one genuine depth layer the eye reads as volume.

  2. RESTRAINT over density.
     Is there generous negative space and ONE clear focal move, or is it packed?
     Could you remove an element and lose nothing? (If yes, you haven't yet.)
     · 0 = dense, multiple competing elements, no air.
     · 2 = the atmosphere has room; nothing is there that doesn't need to be.

  3. ONE idea per section.
     Does it carry exactly one idea the page does not already have, in its own
     words (the one-idea law)? List the existing sections' ideas; confirm no
     collision and no second beat smuggled in.
     · 0 = repeats a shell/other-section beat, or carries two ideas.
     · 2 = one fresh idea, told once, owns the section.

  4. MOTION that MEANS life (never decoration).
     Does every animation map to a named signature (breathe / unfold / draw /
     scrub / field / magnetic / drift / type-bloom) AND signify aliveness or
     reveal structure? Is the easing organic/asymmetric (growth = expo.out w/
     slight overshoot), never linear? Does it honor prefers-reduced-motion?
     · 0 = no motion, OR motion that's pure ornament / a stock fade.
     · 2 = motion is a named signature that means something; reduced-motion safe.

  5. GREEN is sacred (life only).
     Is #3fe081 used ONLY for alive/active/agent-presence states — and nowhere
     as decoration, fill, generic accent, or "make it pop"?
     · 0 = green appears anywhere it isn't signaling life.
     · 2 = green is present only where the organism is alive (or absent — absence
       is fine; misuse is not).

  6. EARNS ITS PLACE / feels inevitable.
     Would a first-time reader be worse off without this section? Does it feel
     inevitable and alive — like it grew here — rather than bolted-on or
     templated? Does TYPE do the heavy lifting (Fraunces display doing the
     emotional work, mono as the machine voice), not chrome?
     · 0 = could be deleted with no loss; reads as filler or a template slot.
     · 2 = load-bearing; the page is incomplete without it; type carries it.

  Max 12. PASS threshold is 9 AND no bar at 0 AND no trigger fired.

## THE REJECT TRIGGERS (PASS B — any single YES = automatic FAIL)

  These are the anti-patterns. They are NON-NEGOTIABLE: one of them present
  means the section reads as generic dark-SaaS no matter how it scored. Walk
  them in order; answer honestly; a hostile reviewer would.

  1. PROSE-BLOB. Is this just "kicker + h2 + 2-4 <p>" with no archetype, no
     motion, no depth — a wall of paragraphs? → FAIL. The prose primitive is
     RETIRED as a default. A section must be an ARCHETYPE (manifesto · mechanism
     · living-proof · comparison · system/layers · field-note · invitation ·
     faq), each with its own composition + motion. Plain prose survives ONLY
     inside field-note (the organism's journal — mono, short) and faq.

  2. GENERIC CARD GRID. Is the content a row/grid of equal bordered cards
     (3-up feature cards, icon+title+blurb tiles)? → FAIL. Enumeration becomes a
     BUILT diagram (system/layers as one constructed object) or a disciplined
     comparison table — never a card grid. No solid-color card backgrounds; color
     arrives as accent on glass.

  3. SLIDE-UP FADE. Does the reveal animation translate-Y + fade-in on scroll
     (the universal SaaS entrance)? → FAIL. Sections UNFOLD — grow from seed
     (scale + clip-path + blur-clear), or draw/scrub into being. If the only
     motion is opacity+translateY, it is decoration, not life.

  4. GREEN-AS-DECORATION. Does #3fe081 appear as an underline, a generic accent,
     a gradient sweep, a "pop" color, a border, or a fill that is NOT signaling
     an alive/active/agent state? → FAIL. Green is the life accent only. (This is
     also bar 5 at 0; it is a trigger because misuse alone disqualifies.)

  5. CENTERED-EVERYTHING. Is the composition centered/symmetrical by default —
     centered h2, centered text column, centered CTA, mirrored layout? → FAIL.
     Break center. Asymmetric grid, off-axis weight, generous one-sided negative
     space. Centering must be a deliberate exception with a reason, not the
     reflex.

  6. SaaS-TEMPLATE RHYTHM. Does the section march to the stock landing cadence —
     uniform vertical bands, even padding, hero→features→logos→CTA predictability,
     every section the same height and rhythm? → FAIL. The page is ONE growing
     organism; sections connect and flow with varied weight and pacing, they do
     not stack as interchangeable equal bands.

  (If you find a NEW way a section reads generic that isn't listed, it still
  fails on bar 6 "feels templated" — and you add the trigger here in the same
  commit. The trigger list grows; it never shrinks to let work through.)

## WORKED EXAMPLE (what a passing run's log looks like)

  : ** ADD run — section "07 · the mechanism" (mechanism archetype)
  :    existing ideas: hero`ecosystem; 01`three layers; 02=person→team→world;
  :      04`what's a workbook; 05`field-note; 06=comparison table.
  :      mine: "how the agent weaves one artifact" — fresh, no collision.
  :    PASS A: depth 2 (fog + glass diagram w/ inner light) · restraint 2 (one
  :      diagram, lots of air) · one-idea 2 (the weave, told once) · motion 2
  :      (draw + scrub, expo.out, reduced-motion stills the draw) · green 2
  :      (only the live agent-dot pulses green) · earns 2 (page had no how-it-
  :      works; Fraunces label carries it) = 12/12
  :    PASS B triggers: prose-blob NO · card-grid NO (it's a built diagram) ·
  :      slide-fade NO (draw+scrub) · green-decoration NO · centered NO (diagram
  :      sits right, label left) · saas-rhythm NO (taller scrub band, breaks the
  :      cadence). 0 triggers.
  :    VERDICT: PASS (12/12, 0 triggers). ship.

## WHY THIS EXISTS (the one rule under all the rules)

  Honesty alone ships truthful templates. This gate is the second discipline:
  the page must be ALIVE and INEVITABLE, not just true. When in doubt, the gate
  is biased toward CUTTING — a page of five sections that each pass is premium;
  a page of nine where four are generic is dark-SaaS with good copy. Restraint
  is the whole aesthetic. Cut first; earn the slot; then make it breathe.
