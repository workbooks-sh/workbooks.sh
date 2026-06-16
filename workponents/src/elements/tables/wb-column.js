// <work-column> — declarative column config for <work-table>. Light-DOM only; it
// renders nothing itself. The parent <work-table> reads these to label, align,
// format, and order columns. Composition-as-source: the columns ARE markup.
//
//   <work-table src-name="orders">
//     <work-column field="region" label="Region"></work-column>
//     <work-column field="rev" label="Revenue" align="right" format="usd"></work-column>
//   </work-table>
//
// Attrs: field (required) · label · align(left|right|center) · format(usd|num|pct|raw) · hidden
import { define } from "../../core/element.js";

export class WbColumn extends HTMLElement {
  static get observedAttributes() { return ["field", "label", "align", "format", "hidden"]; }
  // No shadow / no render — pure config the table reads. Notify parent on change.
  connectedCallback() { this._notify(); }
  attributeChangedCallback() { this._notify(); }
  _notify() {
    const t = this.closest("work-table");
    if (t && typeof t._columnsChanged === "function") t._columnsChanged();
  }
  /** The config object <work-table> consumes. */
  get config() {
    return {
      field: this.getAttribute("field"),
      label: this.getAttribute("label") || this.getAttribute("field"),
      align: this.getAttribute("align") || null,
      format: this.getAttribute("format") || null,
      hidden: this.hasAttribute("hidden"),
    };
  }
}

define("work-column", WbColumn);
