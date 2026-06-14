# presentation

Ask for a presentation, get reveal.js — a real navigable deck with arrow-key nav, `f` fullscreen, `o` overview, and per-slide URLs via the hash, not a long scroll page. The capability is "presentation"; the implementation is reveal.js, swappable behind it.

## When to reach for it

Reach for `presentation` whenever a user asks for a *presentation*, *deck*, or *slides* — don't hand-roll a scroll page. The agent calls the capability and this toolkit resolves it to reveal.js; the impl can be swapped without touching any agent that asks for a presentation.

## Example

Two ways in, by where the content lives:

```
# from a brandnana deck spec (slides as JSON):
brandnana book assemble <spec> --out deck.html   # emits reveal.js
brandnana book publish deck.html

# from an Org workbook: render :slide:/:section: nodes as reveal sections
```

## What it grants

- A single self-contained `.html` deck (reveal from CDN, content inline).
- Two authoring paths: a brandnana deck spec, or an Org workbook's `:slide:`/`:section:` nodes.
- Hard cuts only (`transition:none`) — no fade/wipe, in keeping with the brand.

## Maturity

Stable (v0.1.0).
