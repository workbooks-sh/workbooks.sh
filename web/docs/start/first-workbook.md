
# Your first workbook, end to end

> Write a workbook, run it, and publish it as one self-contained .html — the whole happy path.

A workbook is a single `.org` file that runs. In this tutorial you write one, run
it, and publish it as a self-contained `.html` you can open in any browser. You
need the `wb` CLI ([install it here](install.md)) and nothing else.

This is the shallow, complete happy path — one branch, no detours. For the model
behind each step, follow the links into Build and Concepts.

## 1 · Write the file

A workbook is standard Org with one top-level heading marked as a workbook.

```org
#+TITLE: Hello

* Hello
  :PROPERTIES:
  :WORKBOOK_VERSION: 1
  :END:

Some prose, then a source block the runtime will compile and run.

#+begin_src js
console.log("hello from a workbook");
#+end_src
```

Save it as `hello.org`. See [Anatomy of a workbook](../workbooks/anatomy.md) for the full structure.

## 2 · Run it

```bash
wb run hello.org
```

The runtime parses the Org, compiles each source block to WASM *inside its own
sandbox* — no toolchain on your machine — and runs it.

## 3 · Publish it

```bash
wb publish hello.org
```

The output is one `.html`: prose, compiled WASM, and the source it tangles from,
all inline. Open it in any browser — no server is required to view it.

See [Publish a workbook](../workbooks/publish.md) for providers and options, and
[The build plan](../workbooks/build-plan.md) for what `tangle` derives along the way.

## Where to go next

- Give your workbook a new capability: [Your first toolkit](first-toolkit.md).
- Understand the two surfaces: [Workbooks & toolkits](../concepts/two-surfaces.md).
- The exact CLI verbs: [Reference → wbx CLI](../reference/cli.md).
