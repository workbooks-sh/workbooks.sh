# Create a workbook

A workbook is **plain HTML** built from `work-*` elements. There is no scaffolder
to "init" — you author the HTML directly (the elements are the source of truth).
The smallest valid workbook is one HTML file that pulls the `work-*` library and
nests a few elements.

## Minimal starter — `index.html`

```html
<!doctype html>
<html lang="en" data-work-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="dist/theme.css">
  <script type="module" src="dist/workponents.js"></script>
  <title>My workbook</title>
</head>
<body>
  <!-- A workbook declares WHAT IT IS via the tagging edge. -->
  <work-ref rel="kit"></work-ref>

  <work-doc title="Hello">
    <work-text>The browser renders this. No kernel, no server.</work-text>
  </work-doc>
</body>
</html>
```

Everything is HTML: structure, config, content. **Never** hand-author a sidecar
`.json` to drive rendering — if you reach for one, you're doing it wrong.

## Verify (non-interactive)

```sh
work structure index.html      # outline: the work-* elements + their ids
work content check .           # validate the folder (HTML-first)
```

`work structure` parses the HTML with a standard parser (Floki in the runtime)
and prints the discovered elements — confirm your file shows up with the
elements you authored. `work content check` validates the folder; it defaults to
`.` so run it from the workbook root.

## Next

- Add more elements → `components.md`.
- Add logic → `work-src.md`.
