// <wb-field-group> — a themed fieldset/section that visually groups fields. Pure
// layout + label; it does NOT own a schema (the owning <wb-form> collects every
// <wb-field> beneath it, grouped or not). Styled entirely from --wb-* tokens.
// Usage:
//   <wb-field-group label="Account" help="How you sign in">
//     <wb-field ...></wb-field>
//   </wb-field-group>
import { WbElement, define } from "../../core/element.js";

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export class WbFieldGroup extends WbElement {
  static props = ["label", "help"];

  static styles = `
    :host { display: block; margin: 0 0 var(--wb-space-5); }
    .group { border: 1px solid var(--wb-border); border-radius: var(--wb-radius-lg);
      background: var(--wb-surface); padding: var(--wb-space-5); }
    .legend { font-family: var(--wb-font); font-size: var(--wb-text-lg); font-weight: 600;
      color: var(--wb-fg); margin: 0 0 var(--wb-space-1); letter-spacing: -0.01em; }
    .help { margin: 0 0 var(--wb-space-4); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); line-height: 1.45; }
    ::slotted(*:last-child) { margin-bottom: 0 !important; }
  `;

  render() {
    const label = this.attr("label");
    const help = this.attr("help");
    return `
      <div class="group">
        ${label ? `<div class="legend">${esc(label)}</div>` : ""}
        ${help ? `<p class="help">${esc(help)}</p>` : ""}
        <slot></slot>
      </div>`;
  }
}

define("wb-field-group", WbFieldGroup);
