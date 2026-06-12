# The motion vocabulary — a small named set, not per-element decisions

Motion is canon, like color. The failure mode is deciding an animation per element
as you build — yielding inconsistent durations, clashing easings, and a page that
feels busy. Instead define a **small vocabulary of named motions** in Stage 1 and
compose only from it.

## Define the vocabulary

A handful of motions, each with a FIXED easing and duration, named for what they
do (not how):

| Name | Use | Shape |
|---|---|---|
| `rise-in` | content entering on scroll | translateY + fade, one ease-out |
| `reveal` | a block uncovering (figure, code) | clip/opacity, slightly slower |
| `settle` | hover/press feedback | small transform, fast, snappy |
| `drift` | ambient texture motion | very slow, looped, low-amplitude |

Pin them as tokens so they can't drift:

```css
:root {
  --ease-out: cubic-bezier(.2,.7,.2,1);
  --ease-snap: cubic-bezier(.3,0,.1,1);
  --dur-fast: 140ms; --dur-base: 320ms; --dur-slow: 640ms;
}
```

Every animated element references a named motion. If an element needs a motion not
in the vocabulary, that's a design decision — **add it to the vocabulary**
deliberately, don't one-off it inline.

## The transition policy — decide it once

Decide the cross-element / cross-scene transition policy up front so it can't
fragment:
- **Default to restraint.** Prefer hard, decisive state changes over soft fades
  and wipes where the brand reads as crisp. (For ad/video creative the project
  canon is explicitly *hard cuts only — no fade/crossfade/wipes*; carry the same
  bias to UI unless the brand is deliberately soft.)
- Pick ONE entrance pattern for scroll-revealed content and reuse it; a page where
  every section enters differently feels unsettled.

## Discipline

- **Respect `prefers-reduced-motion`** — every motion has a reduced-motion
  fallback (usually: appear, no transform). This is a premium-bar item, not
  optional.
- **Transform/opacity only** for anything animated on scroll or hover — never
  animate layout properties; keep it on the compositor.
- **Subtle beats loud.** Premium motion is felt, not watched. Large, shadow-heavy,
  attention-grabbing motion reads amateur — the same note as overlay/chrome being
  too big and heavy.

**Gate (Stage 1):** the named motions and the transition policy are written down
before any element is animated.
