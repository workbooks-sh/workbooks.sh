# Bundle — weave the tree into one `.html`

`work bundle` weaves a workbook folder tree into **one gzipped, self-contained
`.html`** (the `wbundle-html/1` format): the page plus a compressed blob of the
tree, hydrated client-side. `work unbundle` recovers the tree losslessly — the
two are a bijection.

## Bundle

```sh
work bundle . dist/index.html
```

- First arg: the source **directory** (the workbook folder).
- Second arg: the **output** `.html` to write.
- The compiler tangles the tree, embeds it as a compressed blob, and emits the
  single page. The output prints how many files were embedded and the blob size.

## Unbundle (round-trip)

```sh
work unbundle dist/index.html out/
```

Recovers every file from the embedded blob into `out/`. Because bundle ⇄ unbundle
is lossless, this is the safe edit loop:

```
unbundle → edit the source tree → re-bundle
```

## LAW: never hand-edit the runnable artifact

Edit **source**, then re-bundle. Hand-editing `dist/index.html` (the bundled
output) breaks the round-trip and smuggles state into a generated artifact. If
you need to change a bundled workbook, `unbundle` it first.

## Verify before bundling

```sh
work content check .       # validate the source folder
work structure index.html  # confirm the expected work-* elements are present
```

Then bundle. To ship the result to a URL, see `deploy.md` (or `work publish`).
