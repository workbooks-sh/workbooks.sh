
# Anatomy of a workbook

> What a workbook is made of and the one rule it must follow.

A workbook is a single `.org` file. The only structural requirement is a top-level
heading marked as a workbook:

```org
#+TITLE: My Workbook

* My Workbook
  :PROPERTIES:
  :WORKBOOK_VERSION: 1
  :END:

Prose, source blocks, and data live here.
```

Everything else is standard Org. The runtime understands Org — you don't learn a
new format. Source blocks become WASM components; the rendered result is a
self-contained `.html`.

Because it's just Org and just HTML, a workbook carries its own source, ships as
one file, and can carry toolkits inside it.

- The two surfaces: [Workbooks & toolkits](../concepts/two-surfaces.md)
- How it compiles: [The build plan](build-plan.md)
