
# Package & sign

> A toolkit ships as a workbook — packed, content-addressed, optionally signed.

A toolkit **is** a workbook, so distribution is the document. Pack it into one
portable `.wbundle` — a zip carrying the HTML, the compiled WASM, and a manifest.

```bash
wb pack my-tool my-tool.wbundle
```

The bundle is content-addressed: its hash is the supply-chain gate. For
third-party distribution, sign it with your `did:key` — the signature authenticates
the manifest (and through it, the artifact) under your identity.

Nothing about this is a new format. It's the same `.wbundle` the rest of the system
produces, the same signing the runtime uses for any artifact. A toolkit is not a
special package — it's a workbook that declares itself a toolkit.

- Install it elsewhere: [Install & registry](install.md)
