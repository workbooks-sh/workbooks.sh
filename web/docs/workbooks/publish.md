
# Publish

> Turn a workbook into a self-contained .html and put it on the web.

Publishing compiles a workbook to a single self-contained `.html` and pushes it to
a provider.

```bash
wb publish my-workbook.org
```

The output is one file: prose, compiled WASM, and the source it tangles from, all
inline. Open it in any browser — no server required to view. The runtime is the
optional tier for agents and sync, never a gate on reading.

- What's inside the file: [Anatomy of a workbook](anatomy.md)
