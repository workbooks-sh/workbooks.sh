# bit.ml — an editorial service run by agents

**The pitch:** if Linear designed the New York Times. A fully agent-managed
editorial site covering AI/ML, technology, and finance/business as
bite-digestible news — fast to scan, precise to read, beautiful the way a
tool is beautiful.

**Status: scaffold.** Design + agent definitions below; the build reuses the
living-lander's proven machinery (runtime keeper, lifecycle, CMS manifests,
real-time presence) and extends it to a multi-agent newsroom.

## What makes it different from the lander

The lander showcases ONE resident agent. bit.ml showcases a NEWSROOM — a
multi-agent workflow board where several agents work the pipeline at once:

    desk (assignment) → research → writing → edit/fact pass → publish

- **The board is the workflow**: a TODO board (the same engine the
  lander's board uses) where each story is a task moving through pipeline
  states; agents claim, work, and hand off.
- **Multiple agents, simultaneously visible.** The inspect panel is redesigned
  for a crew: an always-available toggle (top-right of every page) opens it;
  inside, each agent has a live row — what it's doing now, its current story,
  its last commit. Click an agent → watch IT live: the same true-presence
  system the lander shipped (real anchors, semantic motion, the portal embed)
  scoped to that agent — e.g. watch the writer drafting an article in real
  time.
- **Real-time visuals carry over**: cursor presence, the portal card,
  type-in diffs — all driven by the same public activity feed, extended to
  carry per-agent streams.

## Architecture notes (inherit, don't reinvent)

- Runtime: one engine, multiple keeper agents (or one keeper orchestrating a
  crew via the workflow board) — decide during build against wb-2ku learnings.
- Content: runtime CMS manifests (stories.json + HTML partials), validated by
  `work content check` conventions.
- Presence: /_activity gains agent identity per step; the frontend's state
  machine (on-page / portal / thinking) runs per-agent.
- Models: deliberately undecided (Mercury/diffusion is a candidate for the
  drafting lane; pick during build).

## This folder

- `agents/` — agent defs for the crew (desk, researcher, writer, editor): stubs
  with role, territory, hand-off rules. Written to be runnable by the same
  keeper machinery as the lander's agent.html.
- `board/pipeline.md` — the newsroom board seed: pipeline states + first
  objectives.
