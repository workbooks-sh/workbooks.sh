# orgitorial

An org-mode blogging/CMS toolkit you plug into any site: a zero-dependency org→HTML renderer (browser / Node / QuickJS-wasm), a complete editorial CSS library themed entirely by custom properties, and skills documenting the stable class contract. Plain HTML semantics, no framework.

## When to reach for it

Reach for `orgitorial` when you want to author content in org-mode and render it as clean, themeable HTML on any site — static, server-rendered, or a single file. The contract is the CSS class API: the renderer emits a fixed set of classes, the CSS styles exactly those, so it's framework-agnostic.

## Example

```js
import { render } from "orgitorial";          // link orgitorial.css too
const html = render(orgText, { theme: "dark" });
// consume the string from Svelte, React, or plain HTML — no web components
```

## What it grants

- A pure `render(orgText, opts) -> html` renderer; malformed org degrades to paragraphs, unsupported constructs are preserved as `.org-raw`, never dropped.
- A full editorial stylesheet themed through `--org-*` variables, with light and `[data-org-theme=dark]` defaults.
- The blogging-90% org subset (metadata, headlines, lists/checkboxes, tables, src/quote/example blocks, drawers, footnotes, timestamps).
- Living blocks: a `#+begin_src mermaid` diagram, a `#+begin_src html :app` mini-app, and a `:width` modifier — run by the browser-only `Orgitorial.activate(document)`.

## Maturity

Experimental (v0.2.0). Built to be re-themed, not forked — its `--org-*` vars map onto any brand's tokens.
