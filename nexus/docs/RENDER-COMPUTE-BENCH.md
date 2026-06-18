# Render compute — empirical benchmark (where we stand)

Goal: minimize compute so the Elixir server runs many renders concurrently. Measured the render paths
on real pages of varying difficulty (wall-clock, content yield). The question was never "can the JS
engine render?" — it's "what's the cheapest path that still gives pretty-damn-good results?"

## Numbers (fast = CSS-only Blitz · jsdom = StarlingMonkey+linkedom hydrate → Blitz)

| Page | fast | jsdom | finding |
|------|------|-------|---------|
| example.com | 570ms · 3 lines | 870ms · 3 lines | **identical** output — engine pure waste |
| Hacker News | 738ms · 94 lines | 1290ms · 94 lines | **identical** output — engine pure waste |
| GitHub repo | 8660ms · **488 lines** | 7841ms · **1 line** | jsdom **DESTROYED** content (page JS wiped the SSR DOM; linkedom lacks the browser APIs to rebuild it) |

(Wikipedia returned 0 — a `Nexus.Dock.fetch` block on that host, a separate fetch follow-up, not a render issue.)

## Conclusions
1. **The fast CSS-only path already wins on SSR sites** — which is most of the real web. It returns the
   full content for ~0.4–0.9s; the JS engine adds ~300–550ms to return the *exact same bytes*.
2. **Blindly running JS can REGRESS.** A page whose JS replaces its own SSR content (GitHub) collapses
   from 488 lines to 1 under a JS-DOM that can't fully reproduce a real browser. `--js` must never be
   a blind force.
3. **The ~11MB StarlingMonkey engine is expensive per concurrent call** — reserve it for the rare true
   client-only shell, not the default.

## The policy we shipped (`engine: :auto`, what `scrape --js` uses)
Fast render first → if the result is **thin** (< 5 non-empty lines, i.e. a real client-only shell)
escalate to the JS engine → **keep whichever output is richer.** Never regress, pay the engine cost
only when it can actually help. Verified: HN stays 367ms/94 lines (never escalates); GitHub keeps
488 lines (engine never fires). Default `scrape` (no flag) stays the cheap path.

**Net:** "stick with what works" is empirically correct. The greenfield engine is a *targeted
fallback* for client-only SPAs, not the workhorse — keeping concurrent-render compute low.

## Computer-use standing (measured)

| Mode | Compute | Result |
|------|---------|--------|
| **Tier-1 semantic** (navigate/click/fill/submit, no engine, no vision) | **~633ms/step** (3-step HN nav in 1.9s) | deterministic, fully concurrent-friendly — the workhorse |
| **Multimodal loop** (Gemma 3 12B vision + cheap screenshot) | **~2.9s/step**, model-bound (our render is cheap) | read the HN screenshot + actionables, answered in 1 step |

Both run on the **cheap render path** — no StarlingMonkey. Tier-1 is the cheap deterministic spine;
the vision loop is for when you need a model to *decide* the next action, and its cost is the model
call, not our compute. "Pretty damn good computer-use" is already here without the heavy engine.
