
# Workbooks & toolkits

> The two developer surfaces and how they relate.

You build on two surfaces, and every page in these docs is about one of them.

A **workbook** is the artifact you ship — a single `.org` file that renders and runs,
published as a self-contained `.html`. It's the output: a live document that is
also a program.

A **toolkit** is the capability you build to make a workbook (or an agent) do more —
sandboxed WASM, authored in any language, run isolated, distributed as a workbook.

```text
  WORKBOOK  the document that runs        ← what you ship
  TOOLKIT   the capability it can call     ← what you build to extend it
```

They compose: a toolkit travels **inside** a workbook (the bundle carries its
compiled WASM), and a workbook's HTML can **call** a toolkit live through the Dock.
Distribution is the document — installing a toolkit is installing a workbook.

- [What is a toolkit](what-is-a-toolkit.md)
- [Anatomy of a workbook](../workbooks/anatomy.md)
