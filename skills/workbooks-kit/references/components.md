# Add a `work-*` component

Composition is the source. You compose a workbook by **nesting `work-*` custom
elements as HTML** — the parent owns the contract, hierarchy is DOM nesting.

## The rules (composition-as-source)

- **Scalars and references are attributes.** `model="…"`, `toolkits="crm"`,
  `from="orders"`, `rel="kit"`.
- **Content is child elements or text.** A table's rows are children; a doc's
  prose is its text.
- The themed `work-*` set is just a pre-built library. You can **define your own
  elements in HTML** and reference them; nothing forces you to the built-ins.

## Example — nesting

```html
<work-doc title="Orders">
  <work-text>Last 30 days of orders.</work-text>

  <work-table from="orders">
    <work-col field="id"     label="Order"></work-col>
    <work-col field="total"  label="Total"></work-col>
  </work-table>
</work-doc>
```

The parent (`work-table`) owns the contract for its children (`work-col`).
Scalars (`from`, `field`, `label`) are attributes; rows come from the referenced
data, not inline JSON.

## Confirm it's discovered

After adding an element, re-run the outline:

```sh
work structure index.html
```

The new element should appear in the listing (tagname + id/title). If it
doesn't, the element is malformed or in a part of the tree the parser skips —
fix the HTML, not a config file.

## Validate

```sh
work content check .
```

Keep authoring in HTML. Behavior that needs to compute goes in a
`<work-src>` — see `work-src.md`.
