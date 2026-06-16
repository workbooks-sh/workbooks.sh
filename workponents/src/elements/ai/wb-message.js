// <work-message> — one turn of a conversation. Ported from
// desktop/src/lib/chat/AssistantMessageView.svelte (+ the role bubble chrome).
//
// The body is the message's living source (markdown / org-with-components).
// It renders SANITIZED markdown (bold/italic/lists/headings/code/links — see
// ./markdown.js, HTML-escaped first) and weaves inline `#+begin_src component`
// blocks into <work-gen-block> cards in document order. The agent edits this
// source; the rendered turn is the view of it (preview ≡ source).
//
// Usage:
//   <work-message role="user">What changed in the deploy?</work-message>
//   <work-message role="assistant">**Done.** Here is the diff…</work-message>
//
// `role` styles the turn (user | assistant | system | tool). The body can be
// passed as light-DOM textContent or via the `text` attribute/property.
import { WbElement, html, css, define } from "../../core/element.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { renderMarkdown, splitComponents } from "./markdown.js";
import "./wb-gen-block.js";

const VARIANTS = defineVariants({
  role: { options: ["user", "assistant", "system", "tool"], default: "assistant" },
});

export class WbMessage extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "text", "name"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .turn { display: flex; flex-direction: column; gap: var(--work-space-1); }
    .meta { display: flex; align-items: center; gap: var(--work-space-2);
      font: 600 11px var(--work-font-mono); letter-spacing: .08em; text-transform: uppercase;
      color: var(--work-fg-subtle); }
    .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--work-fg-subtle); }
    .body {
      font-size: var(--work-text); line-height: 1.55;
      display: flex; flex-direction: column; gap: var(--work-space-3);
    }

    /* user turn: a brand-tinted bubble, right-shouldered */
    :host([role="user"]) .turn { align-items: flex-end; }
    :host([role="user"]) .body {
      background: var(--work-brand-soft); color: var(--work-fg);
      border: 1px solid color-mix(in srgb, var(--work-brand) 24%, transparent);
      border-radius: var(--work-radius-lg);
      padding: var(--work-space-3) var(--work-space-4);
      max-width: 80%;
    }
    :host([role="user"]) .dot { background: var(--work-brand); }

    /* assistant turn: flat on the surface */
    :host([role="assistant"]) .body { max-width: 100%; }

    /* system / tool: muted monospace card */
    :host([role="system"]) .body,
    :host([role="tool"]) .body {
      font-family: var(--work-font-mono); font-size: var(--work-text-sm);
      color: var(--work-fg-muted); background: var(--work-surface-soft);
      border: 1px solid var(--work-border); border-radius: var(--work-radius-sm);
      padding: var(--work-space-2) var(--work-space-3);
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
    .md li::marker { color: var(--work-fg-muted); }
    .md code { font-family: var(--work-font-mono); font-size: .88em;
      background: var(--work-surface-soft); border: 1px solid var(--work-border);
      border-radius: 4px; padding: .05em .3em; }
    .md pre { margin: .4em 0 .55em; padding: .6em .75em; background: var(--work-surface-soft);
      border: 1px solid var(--work-border); border-radius: 7px; overflow-x: auto; }
    .md pre code { background: none; border: 0; padding: 0; font-size: .85em; }
    .md a { color: var(--work-brand); text-decoration: underline; text-underline-offset: 2px; }
  `;

  /** Source: explicit `text` prop/attr, else light-DOM textContent. */
  get source() {
    if (this._text != null) return this._text;
    if (this.hasAttribute("text")) return this.getAttribute("text");
    return (this._initialText ?? "").trim();
  }
  set text(v) {
    this._text = v;
    if (this._connected) this.requestUpdate();
  }

  connectedCallback() {
    // Capture light-DOM text once for the textContent path (shadow render
    // leaves light DOM intact).
    if (this._initialText == null) this._initialText = this.textContent || "";
    this._connected = true;
    super.connectedCallback();
  }

  render() {
    const role = this.attr("role", "assistant");
    const name = this.attr("name") || role;
    const segments = splitComponents(this.source);

    return html`<div class="turn">
      <div class="meta"><span class="dot"></span><span>${name}</span></div>
      <div class="body">${segments.map((seg) =>
        seg.kind === "prose"
          ? html`<div class="md">${unsafeHTML(renderMarkdown(seg.source))}</div>`
          : this._genBlock(seg),
      )}</div>
    </div>`;
  }

  /** Render a component segment as a <work-gen-block> with structured props. */
  _genBlock(seg) {
    const el = document.createElement("work-gen-block");
    el.setAttribute("type", seg.type);
    for (const [k, v] of Object.entries(seg.props)) el.setAttribute(k, v);
    el.textContent = seg.body;
    return el;
  }
}

define("work-message", WbMessage);
