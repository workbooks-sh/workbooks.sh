// <work-field> — one control bound to its rule. The form IS its schema: a field
// carries its own declarative rule (inline JSON `rule` attr/property, or built
// from the validation attrs name/type/required/min/max/pattern), and reflects
// its own validity — it is not hand-wired per field. The owning <work-form>
// collects fields, runs `src/validate`, and writes errors back down.
//
// Renders the right control by `type` (text/number/email/select/checkbox/
// textarea/date). Label + help + error are themed entirely from --wb-* tokens.
// Usage:
//   <work-field name="email" type="email" label="Email" required></work-field>
//   <work-field name="role" type="select" label="Role" options="eng,design,ops"></work-field>
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  variant: { options: ["outline", "soft", "ghost"], default: "outline" },
  size: { options: ["sm", "md", "lg"], default: "md" },
});

const TYPES = ["text", "number", "email", "url", "password", "select", "checkbox", "textarea", "date", "tel"];

export class WbField extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "name", "type", "label", "help", "placeholder", "value",
    "required", "min", "max", "pattern", "options", "disabled", "error",
  ];

  static styles = css`
    :host { display: block; margin: 0 0 var(--wb-space-4); font-family: var(--wb-font); }
    .label { display: block; font-size: var(--wb-text-sm); font-weight: 600; color: var(--wb-fg);
      margin-bottom: var(--wb-space-2); }
    .req { color: var(--wb-err); margin-left: 2px; }

    .control { font: inherit; font-size: var(--wb-text); color: var(--wb-fg);
      width: 100%; box-sizing: border-box;
      padding: var(--wb-space-3) var(--wb-space-3);
      border-radius: var(--wb-radius); border: 1.5px solid var(--wb-border-strong);
      background: var(--wb-surface);
      transition: border-color var(--wb-dur) var(--wb-ease), box-shadow var(--wb-dur) var(--wb-ease),
                  background var(--wb-dur) var(--wb-ease); }
    .control::placeholder { color: var(--wb-fg-subtle); }
    .control:focus { outline: none; border-color: var(--wb-brand); box-shadow: 0 0 0 3px var(--wb-ring); }
    textarea.control { min-height: 88px; resize: vertical; line-height: 1.5; }
    select.control { appearance: none; cursor: pointer;
      background-image: linear-gradient(45deg, transparent 50%, var(--wb-fg-muted) 50%),
                        linear-gradient(135deg, var(--wb-fg-muted) 50%, transparent 50%);
      background-position: calc(100% - 18px) calc(50% - 2px), calc(100% - 13px) calc(50% - 2px);
      background-size: 5px 5px, 5px 5px; background-repeat: no-repeat; padding-right: var(--wb-space-5); }

    :host([variant="soft"]) .control { background: var(--wb-surface-soft); border-color: transparent; }
    :host([variant="ghost"]) .control { background: transparent; border-color: transparent; border-bottom: 1.5px solid var(--wb-border-strong); border-radius: 0; padding-left: 0; padding-right: 0; }

    :host([size="sm"]) .control { font-size: var(--wb-text-sm); padding: var(--wb-space-2) var(--wb-space-3); border-radius: var(--wb-radius-sm); }
    :host([size="lg"]) .control { font-size: var(--wb-text-lg); padding: var(--wb-space-4); border-radius: var(--wb-radius-lg); }

    .check { display: inline-flex; align-items: center; gap: var(--wb-space-2); cursor: pointer; font-size: var(--wb-text); }
    .check input { width: 18px; height: 18px; accent-color: var(--wb-brand); cursor: pointer; }

    .help { margin: var(--wb-space-2) 0 0; font-size: var(--wb-text-sm); color: var(--wb-fg-muted); line-height: 1.45; }
    .error { margin: var(--wb-space-2) 0 0; font-size: var(--wb-text-sm); color: var(--wb-err);
      font-weight: 500; line-height: 1.45; display: none; }

    /* invalid state — purely from tokens */
    :host([invalid]) .control { border-color: var(--wb-err); }
    :host([invalid]) .control:focus { box-shadow: 0 0 0 3px rgba(201,47,47,0.28); }
    :host([invalid]) .error { display: block; }
    :host([invalid]) .help { display: none; }

    :host([disabled]) { opacity: 0.55; }
    :host([disabled]) .control, :host([disabled]) .check { pointer-events: none; }
  `;

  /** The declarative rule for this field — explicit `rule` property/attr wins,
   *  otherwise built from the validation attributes (schema-as-source). */
  get rule() {
    if (this._rule) return this._rule;
    const attrRule = this.attr("rule");
    if (attrRule) { try { return JSON.parse(attrRule); } catch { /* fall through */ } }
    const type = (this.attr("type", "text") || "text").toLowerCase();
    const r = { type: this._ruleType(type), label: this.attr("label") || this.attr("name") || "This field" };
    if (this.boolAttr("required")) r.required = true;
    if (this.hasAttribute("min")) r.min = Number(this.getAttribute("min"));
    if (this.hasAttribute("max")) r.max = Number(this.getAttribute("max"));
    if (this.hasAttribute("pattern")) r.pattern = this.getAttribute("pattern");
    if (this.hasAttribute("options")) r.enum = this._optionList().map((o) => o.value);
    return r;
  }
  set rule(v) { this._rule = v; this.requestUpdate(); }

  _ruleType(type) {
    if (type === "number") return "number";
    if (type === "email") return "email";
    if (type === "url") return "url";
    if (type === "date") return "date";
    if (type === "checkbox") return "boolean";
    return "string";
  }

  get name() { return this.attr("name", ""); }

  _controlEl() {
    return this.shadowRoot && this.shadowRoot.querySelector(".control");
  }

  /** Current control value (typed). */
  get value() {
    const ctl = this._controlEl();
    const type = (this.attr("type", "text") || "text").toLowerCase();
    if (!ctl) return this.attr("value", type === "checkbox" ? false : "");
    if (type === "checkbox") return ctl.checked;
    return ctl.value;
  }
  set value(v) {
    this.setAttribute("value", v == null ? "" : String(v));
    const ctl = this._controlEl();
    if (ctl) { const type = (this.attr("type", "text") || "text").toLowerCase(); if (type === "checkbox") ctl.checked = !!v; else ctl.value = v; }
  }

  /** Show / clear the field's error (called by <work-form>); reflects validity.
   *  The `error` attr drives the Lit `.error` binding; we also write the node's
   *  text synchronously so a read right after setError (before Lit's async flush)
   *  already reflects it. */
  setError(message) {
    if (message) { this.setAttribute("invalid", ""); this.setAttribute("error", message); }
    else { this.removeAttribute("invalid"); this.removeAttribute("error"); }
    const el = this.shadowRoot && this.shadowRoot.querySelector(".error");
    if (el) el.textContent = message || "";
  }
  clearError() { this.setError(null); }

  _optionList() {
    const raw = this.attr("options", "") || "";
    return raw.split(",").map((s) => s.trim()).filter(Boolean).map((tok) => {
      const i = tok.indexOf(":");
      return i > -1 ? { value: tok.slice(0, i), label: tok.slice(i + 1) } : { value: tok, label: tok };
    });
  }

  // Bubble a normalized input/change/blur event up to the owning <work-form> so it
  // can re-validate live. Dispatched on the host (this) so the form's delegated
  // listener catches it; .control's native event handlers route here.
  _fire(kind) {
    this.dispatchEvent(new CustomEvent("work-field-" + kind, {
      bubbles: true, composed: true, detail: { name: this.name, value: this.value },
    }));
  }

  _control() {
    const type = (this.attr("type", "text") || "text").toLowerCase();
    const t = TYPES.includes(type) ? type : "text";
    const name = this.name;
    const ph = this.attr("placeholder");
    const val = this.attr("value");
    const disabled = this.boolAttr("disabled");
    const onInput = () => this._fire("input");
    const onBlur = () => this._fire("blur");

    if (t === "checkbox") {
      return html`<label class="check"><input class="control" type="checkbox" name=${name}
          ?checked=${val === "true"} ?disabled=${disabled}
          @input=${onInput} @change=${onInput} @blur=${onBlur} />
        <span>${this.attr("label", "")}</span></label>`;
    }
    if (t === "textarea") {
      return html`<textarea class="control" name=${name} placeholder=${ph ?? ""}
        ?disabled=${disabled} @input=${onInput} @change=${onInput} @blur=${onBlur}
        .value=${val || ""}></textarea>`;
    }
    if (t === "select") {
      const opts = this._optionList();
      return html`<select class="control" name=${name} ?disabled=${disabled}
        @input=${onInput} @change=${onInput} @blur=${onBlur} .value=${val ?? ""}>
        ${ph ? html`<option value="" ?selected=${!val} disabled hidden>${ph}</option>` : null}
        ${opts.map((o) => html`<option value=${o.value} ?selected=${val === o.value}>${o.label}</option>`)}
      </select>`;
    }
    return html`<input class="control" type=${t} name=${name}
      placeholder=${ph ?? ""} .value=${val ?? ""}
      min=${this.hasAttribute("min") ? this.getAttribute("min") : ""}
      max=${this.hasAttribute("max") ? this.getAttribute("max") : ""}
      ?disabled=${disabled} @input=${onInput} @change=${onInput} @blur=${onBlur} />`;
  }

  render() {
    const type = (this.attr("type", "text") || "text").toLowerCase();
    const label = this.attr("label");
    const help = this.attr("help");
    const error = this.attr("error");
    const req = this.boolAttr("required");
    // checkbox renders its own inline label inside .check
    const labelHtml = label && type !== "checkbox"
      ? html`<label class="label">${label}${req ? html`<span class="req">*</span>` : null}</label>` : null;
    return html`
      ${labelHtml}
      ${this._control()}
      ${help ? html`<p class="help">${help}</p>` : null}
      <p class="error">${error || ""}</p>
    `;
  }
}

define("work-field", WbField);
