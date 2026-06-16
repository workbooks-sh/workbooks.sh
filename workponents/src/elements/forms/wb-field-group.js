// <work-field-group> — a themed fieldset/section that visually groups fields. Pure
// layout + label; it does NOT own a schema (the owning <work-form> collects every
// <work-field> beneath it, grouped or not). Styled entirely from --work-* tokens.
// Usage:
//   <work-field-group label="Account" help="How you sign in">
//     <work-field ...></work-field>
//   </work-field-group>
import { WbElement, html, css, define } from "../../core/element.js";

export class WbFieldGroup extends WbElement {
  static props = ["label", "help"];

  static styles = css`
    :host { display: block; margin: 0 0 var(--work-space-5); }
    .group { border: 1px solid var(--work-border); border-radius: var(--work-radius-lg);
      background: var(--work-surface); padding: var(--work-space-5); }
    .legend { font-family: var(--work-font); font-size: var(--work-text-lg); font-weight: 600;
      color: var(--work-fg); margin: 0 0 var(--work-space-1); letter-spacing: -0.01em; }
    .help { margin: 0 0 var(--work-space-4); font-size: var(--work-text-sm); color: var(--work-fg-muted); line-height: 1.45; }
    ::slotted(*:last-child) { margin-bottom: 0 !important; }
  `;

  render() {
    const label = this.attr("label");
    const help = this.attr("help");
    return html`
      <div class="group">
        ${label ? html`<div class="legend">${label}</div>` : null}
        ${help ? html`<p class="help">${help}</p>` : null}
        <slot></slot>
      </div>`;
  }
}

define("work-field-group", WbFieldGroup);
