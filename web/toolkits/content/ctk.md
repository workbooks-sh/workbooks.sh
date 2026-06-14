# ctk

CTK — the Component ToolKit — is a standard rendering shell for an isolated artifact (a component or page, in any language the stage can host). It gives you one fixed frame every time: a top bar (size / vibe / gallery), a left control panel, and a stage. Authoring a CTK story is "plug in a component + write a control table," never "design a UI."

## When to reach for it

Reach for CTK when a human or the agent needs to *see and tune* a component in isolation — iterating vibes, sizes, and states with a human-in-the-loop checkpoint in the agent loop. Don't use it to ship a finished app (that's a workbook) or for CLI automation (that's a `command`/`posix` toolkit).

## Example

The variable part is one embedded Org control-spec that does double duty: a table declares the controls, and a `:tangle` block carries the component source. The shell parses the table to build the panel and imports the tangled source to render — so editing the Org edits the component. The reference artifact is `ctk.html`: a self-contained shell plus the FolderIcon story in one openable file.

## What it grants

- A fixed render shell (`#+EXEC: component`, `#+KIND: render`) the runtime can load, read the spec, drive the controls, and observe the result.
- Org-tangled controls — one spec is both the UI panel and the component source.
- A human-in-the-loop review loop the agent can open, await, and commit against.

## Maturity

Experimental. It is also a worked example of toolkit authoring — Org-driven UI, tangling, and the `render` EXEC shape.
