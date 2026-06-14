# toolkit-forge

The self-hosting toolkit: it teaches an agent how to BUILD another toolkit. Given a target — an npm package name, a GitHub URL, or a semantic need ("I need PDF manipulation") — the skills walk the agent through resolving and fetching the target, studying its *real* CLI/API surface (never training priors), designing the progressive-disclosure skill map, authoring deep empirically-verified skills, and verifying the result, to the `toolkits/AUTHORING.org` standard.

## When to reach for it

Reach for `toolkit-forge` when you want to wrap a CLI, package, or capability an agent will reuse. Don't use it for a one-off shell incantation (just run it), or to edit an existing toolkit's prose (edit the `.org` files directly).

## Example

The "tool" here is `git` (clone targets) + `node`/`npm` (resolve packages) + the agent's own bash, driven by the authoring standard. A Claude Code session can run the whole pipeline via the `forge-toolkit` Workflow (`/forge-toolkit <target>`); a runtime agent with only bash reads these skills to do it by hand.

## What it grants

- A research → study-surface → design-skills → author-deep-skill → write-manifest → verify loop.
- The discipline of mapping a target's *real* commands and gotchas from source, not from priors.
- Output: a complete toolkit at `toolkits/<name>/`, consistent in depth/breadth with `ffmpeg/`.

## Maturity

Experimental (v0.1.0). Requires git 2.30+ and Node 20+. It has no bespoke CLI of its own.
