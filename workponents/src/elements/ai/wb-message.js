// <wb-message> — one turn of a conversation. Ported from
// desktop/src/lib/chat/AssistantMessageView.svelte (+ the role bubble chrome).
//
// The body is the message's living source (markdown / org-with-components).
// It renders SANITIZED markdown (bold/italic/lists/headings/code/links — see
// ./markdown.js, HTML-escaped first) and weaves inline `#+begin_src component`
// blocks into <wb-gen-block> cards in document order. The agent edits this
// source; the rendered turn is the view of it (preview ≡ source).
//
// Usage:
//   <wb-message role="user">What changed in the deploy?</wb-message>
//   <wb-message role="assistant">**Done.** Here is the diff…</wb-message>
//
// `role` styles the turn (user | assistant | system | tool). The body can be
// passed as light-DOM textContent or via the `text` attribute/property.
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { renderMarkdown, splitComponents, esc } from "./markdown.js";
import "./wb-gen-block.js";

const VARIANTS = defineVariants({
  role: { options: ["user", "assistant", "system", "tool"], default: "assistant" },
});

export class WbMessage extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "text", "name"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .turn { display: flex; flex-direction: column; gap: var(--wb-space-1); }
    .meta { display: flex; align-items: center; gap: var(--wb-space-2);
      font: 600 11px var(--wb-font-mono); letter-spacing: .08em; text-transform: uppercase;
      color: var(--wb-fg-subtle); }
    .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--wb-fg-subtle); }
    .body {
      font-size: var(--wb-text); line-height: 1.55;
      display: flex; flex-direction: column; gap: var(--wb-space-3);
    }

    /* user turn: a brand-tinted bubble, right-shouldered */
    :host([role="user"]) .turn { align-items: flex-end; }
    :host([role="user"]) .body {
      background: var(--wb-brand-soft); color: var(--wb-fg);
      border: 1px solid color-mix(in srgb, var(--wb-brand) 24%, transparent);
      border-radius: var(--wb-radius-lg);
      padding: var(--wb-space-3) var(--wb-space-4);
      max-width: 80%;
    }
    :host([role="user"]) .dot { background: var(--wb-brand); }

    /* assistant turn: flat on the surface */
    :host([role="assistant"]) .body { max-width: 100%; }

    /* system / tool: muted monospace card */
    :host([role="system"]) .body,
    :host([role="tool"]) .body {
      font-family: var(--wb-font-mono); font-size: var(--wb-text-sm);
      color: var(--wb-fg-muted); background: var(--wb-surface-soft);
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      padding: var(--wb-space-2) var(--wb-space-3);
    }

    /* rendered markdown rhythm */
    .md > *:first-child { margin-top: 0; }
    .md > *:last-child { margin-bottom: 0; }
    .md p { margin: 0 0 .5em; }
    .md strong { font-weight: 650; }
    .md em { font-style: italic; }
    .md h1, .md h2, .md h3 { margin: .6em 0 .35em; line-height: 1.3; font-weight: 650; }
    .md h1 { font-size: 1.18em; } .md h2 { font-size: 1.1em; } .md h3 { font-size: 1.02em; }
    .md ul, .md ol { margin: .25em 0 .5em; padding-left: 1.35em; }
    .md li { margin: .15em 0; }
    .md li::marker { color: var(--wb-fg-muted); }
    .md code { font-family: var(--wb-font-mono); font-size: .88em;
      background: var(--wb-surface-soft); border: 1px solid var(--wb-border);
      border-radius: 4px; padding: .05em .3em; }
    .md pre { margin: .4em 0 .55em; padding: .6em .75em; background: var(--wb-surface-soft);
      border: 1px solid var(--wb-border); border-radius: 7px; overflow-x: auto; }
    .md pre code { background: none; border: 0; padding: 0; font-size: .85em; }
    .md a { color: var(--wb-brand); text-decoration: underline; text-underline-offset: 2px; }
  `;

  /** Source: explicit `text` prop/attr, else light-DOM textContent. */
  get source() {
    if (this._text != null) return this._text;
    if (this.hasAttribute("text")) return this.getAttribute("text");
    return (this._initialText ?? "").trim();
  }
  set text(v) {
    this._text = v;
    if (this._connected) this.update();
  }

  connectedCallback() {
    // Capture light-DOM text BEFORE the base wipes nothing (shadow render
    // leaves light DOM intact, but read it once for the textContent path).
    if (this._initialText == null) this._initialText = this.textContent || "";
    super.connectedCallback();
  }

  render() {
    const role = this.attr("role", "assistant");
    const name = this.attr("name") || role;
    const segments = splitComponents(this.source);

    const bodyParts = segments
      .map((seg) =>
        seg.kind === "prose"
          ? `<div class="md">${renderMarkdown(seg.source)}</div>`
          : this._genBlock(seg),
      )
      .join("");

    return `<div class="turn">
      <div class="meta"><span class="dot"></span><span>${esc(name)}</span></div>
      <div class="body">${bodyParts}</div>
    </div>`;
  }

  /** Render a component segment as a <wb-gen-block> with structured attrs. */
  _genBlock(seg) {
    const attrs = Object.entries(seg.props)
      .map(([k, v]) => `${esc(k)}="${esc(v)}"`)
      .join(" ");
    return `<wb-gen-block type="${esc(seg.type)}" ${attrs}>${esc(seg.body)}</wb-gen-block>`;
  }
}

define("wb-message", WbMessage);
