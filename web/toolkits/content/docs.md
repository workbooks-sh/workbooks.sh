# docs

The documentation pipeline that builds `docs.workbooks.sh`, packaged so any tenant can point it at their own code and inherit the same skeleton: a Diátaxis-shaped org source, reference auto-tangled from your own code, a fail-closed honesty/maturity gate, and agent/SEO output (`.md` siblings, `llms.txt`, `sitemap.xml`, schema.org).

## When to reach for it

Reach for `docs` when a project needs real documentation that can't silently drift from its code. The differentiator is the drift gate: reference is tangled from `:SRC:` anchors in live source, re-hashed, and a mismatch fails the build — "code changed, docs didn't" becomes a mechanical red build, not a review judgement.

## Example

```
# author with the docs-authoring skill, then run the wbx docs verb family:
wbx docs new reference/my-api    # scaffold a page (north-star)
wbx docs build                   # render + assemble (render/deploy half is partial)
wbx docs drift                   # the keystone CI gate (north-star)
```

## What it grants

- A reusable Diátaxis IA over org source, reused — not reinvented — on top of `orgitorial` (renderer), `publish` (identity), and `wbx tangle`/`lint`.
- A maturity discipline: required fields per tier (`:EVIDENCE:`, `:CAVEAT:`, `:WALL:`) so an unkept claim can't ship.
- Agent/SEO emitters: `.md` siblings, `llms.txt`, `llms-full.txt`, `sitemap.xml`, schema.org, Pagefind.

## Maturity

Partial — and honest about it. The render + deploy half works today via `Workbooks.Publish.Site.build/1` (org→HTML, then `wrangler pages deploy`). The `wbx docs` verb family is **not yet wired into the CLI** — `new`, `drift`, `untangle`, and `serve` are north-star; scaffolding and the honesty gate are done by hand against the `docs-authoring` skill until the verbs land. Do not present the unbuilt verbs as shipping.
