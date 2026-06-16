// <work-button> — the reference element. Proves the conventions on the Lit base:
// token-only styling, the variant contract (variant/size/tone as reflected attrs
// targeted in CSS), shadow-DOM isolation, the WbElement base, and define().
// Every other element follows this shape.
// Usage: <work-button variant="solid" tone="brand" size="md">Save</work-button>
import { WbElement, html, css, define } from "../core/element.js";
import { defineVariants, variantAttrs } from "../core/variants.js";

const VARIANTS = defineVariants({
  variant: { options: ["solid", "soft", "outline", "ghost"], default: "solid" },
  size: { options: ["sm", "md", "lg"], default: "md" },
  tone: { options: ["brand", "neutral", "ok", "warn", "err"], default: "brand" },
});

export class WbButton extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "disabled"];

  static styles = css`
    :host { display: inline-block; }
    button {
      font-family: var(--wb-font);
      font-weight: 600;
      font-size: var(--wb-text);
      line-height: 1;
      display: inline-flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-3) var(--wb-space-4);
      border-radius: var(--wb-radius);
      border: 1.5px solid transparent;
      background: var(--wb-brand); color: var(--wb-on-brand);
      cursor: pointer;
      transition: transform var(--wb-dur) var(--wb-ease),
                  background var(--wb-dur) var(--wb-ease),
                  border-color var(--wb-dur) var(--wb-ease),
                  box-shadow var(--wb-dur) var(--wb-ease);
    }
    button:hover { transform: translateY(-1px); }
    button:active { transform: translateY(0); }
    button:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }

    /* tone sets the accent the variants paint with */
    :host([tone="neutral"]) button { --_a: var(--wb-fg); --_ink: var(--wb-surface); --_soft: var(--wb-surface-soft); }
    :host([tone="ok"])      button { --_a: var(--wb-ok);  --_ink: #fff; --_soft: var(--wb-brand-soft); }
    :host([tone="warn"])    button { --_a: var(--wb-warn);--_ink: #1c1304; --_soft: rgba(184,134,27,0.14); }
    :host([tone="err"])     button { --_a: var(--wb-err); --_ink: #fff; --_soft: rgba(201,47,47,0.14); }
    button { --_a: var(--wb-brand); --_ink: var(--wb-on-brand); --_soft: var(--wb-brand-soft); }

    /* variant decides how the tone is applied */
    :host([variant="solid"])   button { background: var(--_a); color: var(--_ink); }
    :host([variant="soft"])    button { background: var(--_soft); color: var(--_a); }
    :host([variant="outline"]) button { background: transparent; color: var(--_a); border-color: var(--_a); }
    :host([variant="ghost"])   button { background: transparent; color: var(--_a); }
    :host([variant="ghost"])   button:hover,
    :host([variant="outline"]) button:hover { background: var(--_soft); }

    /* size */
    :host([size="sm"]) button { font-size: var(--wb-text-sm); padding: var(--wb-space-2) var(--wb-space-3); border-radius: var(--wb-radius-sm); }
    :host([size="lg"]) button { font-size: var(--wb-text-lg); padding: var(--wb-space-4) var(--wb-space-5); border-radius: var(--wb-radius-lg); }

    :host([disabled]) button { opacity: 0.5; pointer-events: none; }
  `;

  render() {
    return html`<button part="button"><slot></slot></button>`;
  }
}

define("work-button", WbButton);
