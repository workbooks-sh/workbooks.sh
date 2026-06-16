// <work-field> — one control bound to its rule. The form IS its schema: a field
// carries its own declarative rule (inline JSON `rule` attr/property, or built
// from the validation attrs name/type/required/min/max/pattern), and reflects
// its own validity — it is not hand-wired per field. The owning <work-form>
// collects fields, runs `src/validate`, and writes errors back down.
//
// Form-Associated Custom Element (FACE) — rides the platform standard: with
// `static formAssociated = true` + ElementInternals (attachInternals), a
// <work-field> participates in a native <form> exactly like a built-in input —
// its value is submitted (setFormValue, named by `name`), its validity surfaces
// through native constraint validation (setValidity, fed by the EXISTING
// src/validate layer), and its state is exposed as CustomStateSet entries
// (:state(invalid|required|disabled)). The owning <work-form> no longer hand-
// harvests DOM values; it reads native form participation. Degrades cleanly when
// attachInternals / CustomStateSet are unavailable (older engines) — the reflected
// attributes ([invalid]/[required]/[disabled]) remain a styling fallback.
//
// Renders the right control by `type` (text/number/email/select/checkbox/
// textarea/date). Label + help + error are themed entirely from --work-* tokens.
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
  // Form-Associated Custom Element: opt into native <form> participation so the
  // browser submits this element's value and runs its validity like a built-in.
  static formAssociated = true;

  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "name", "type", "label", "help", "placeholder", "value",
    "required", "min", "max", "pattern", "options", "disabled", "error",
  ];

  constructor() {
    super();
    // attachInternals gives us the FACE surface (setFormValue/setValidity/states).
    // Guarded — older engines (and some test stubs) lack it; the element then
    // degrades to the reflected-attribute styling path with no behavior loss.
    this._internals = typeof this.attachInternals === "function" ? this.attachInternals() : null;
  }

  /** The CustomStateSet (this._internals.states) when supported, else null.
   *  Used to expose :state(invalid|required|disabled) without reflecting attrs. */
  get _states() {
    const s = this._internals && this._internals.states;
    // Some engines expose `states` but not the Set API; feature-detect `add`.
    return s && typeof s.add === "function" ? s : null;
  }

  /** Mirror a boolean condition into the CustomStateSet (modern :state() styling).
   *  The attribute fallback is left to the caller — `invalid` is owned by this
   *  element (setError sets the attr too), while `required`/`disabled` are
   *  author-set attributes we only MIRROR into states. */
  _setState(name, on) {
    const states = this._states;
    if (!states) return;
    if (on) states.add(name); else states.delete(name);
  }

  /** Sync the author-set required/disabled attributes into :state() so
   *  :host(:state(required|disabled)) matches alongside the [required]/[disabled]
   *  fallback selectors. Runs on connect + on attribute change. */
  _syncAuthorStates() {
    this._setState("required", this.boolAttr("required"));
    this._setState("disabled", this.boolAttr("disabled"));
  }

  static styles = css`
    :host { display: block; margin: 0 0 var(--work-space-4); font-family: var(--work-font); }
    .label { display: block; font-size: var(--work-text-sm); font-weight: 600; color: var(--work-fg);
      margin-bottom: var(--work-space-2); }
    .req { color: var(--work-err); margin-left: 2px; }

    .control { font: inherit; font-size: var(--work-text); color: var(--work-fg);
      width: 100%; box-sizing: border-box;
      padding: var(--work-space-3) var(--work-space-3);
      border-radius: var(--work-radius); border: 1.5px solid var(--work-border-strong);
      background: var(--work-surface);
      transition: border-color var(--work-dur) var(--work-ease), box-shadow var(--work-dur) var(--work-ease),
                  background var(--work-dur) var(--work-ease); }
    .control::placeholder { color: var(--work-fg-subtle); }
    .control:focus { outline: none; border-color: var(--work-brand); box-shadow: 0 0 0 3px var(--work-ring); }
    textarea.control { min-height: 88px; resize: vertical; line-height: 1.5; }
    select.control { appearance: none; cursor: pointer;
      background-image: linear-gradient(45deg, transparent 50%, var(--work-fg-muted) 50%),
                        linear-gradient(135deg, var(--work-fg-muted) 50%, transparent 50%);
      background-position: calc(100% - 18px) calc(50% - 2px), calc(100% - 13px) calc(50% - 2px);
      background-size: 5px 5px, 5px 5px; background-repeat: no-repeat; padding-right: var(--work-space-5); }

    :host([variant="soft"]) .control { background: var(--work-surface-soft); border-color: transparent; }
    :host([variant="ghost"]) .control { background: transparent; border-color: transparent; border-bottom: 1.5px solid var(--work-border-strong); border-radius: 0; padding-left: 0; padding-right: 0; }

    :host([size="sm"]) .control { font-size: var(--work-text-sm); padding: var(--work-space-2) var(--work-space-3); border-radius: var(--work-radius-sm); }
    :host([size="lg"]) .control { font-size: var(--work-text-lg); padding: var(--work-space-4); border-radius: var(--work-radius-lg); }

    .check { display: inline-flex; align-items: center; gap: var(--work-space-2); cursor: pointer; font-size: var(--work-text); }
    .check input { width: 18px; height: 18px; accent-color: var(--work-brand); cursor: pointer; }

    .help { margin: var(--work-space-2) 0 0; font-size: var(--work-text-sm); color: var(--work-fg-muted); line-height: 1.45; }
    .error { margin: var(--work-space-2) 0 0; font-size: var(--work-text-sm); color: var(--work-err);
      font-weight: 500; line-height: 1.45; display: none; }

    /* invalid state — purely from tokens. Drive off the CustomStateSet
       (:state(invalid)) when the engine supports it; keep the reflected
       [invalid] attribute selector as the fallback for engines without
       ElementInternals/CustomStateSet. */
    :host(:state(invalid)) .control,
    :host([invalid]) .control { border-color: var(--work-err); }
    :host(:state(invalid)) .control:focus,
    :host([invalid]) .control:focus { box-shadow: 0 0 0 var(--work-space-3px) var(--work-err-glow); }
    :host(:state(invalid)) .error,
    :host([invalid]) .error { display: block; }
    :host(:state(invalid)) .help,
    :host([invalid]) .help { display: none; }

    :host(:state(disabled)),
    :host([disabled]) { opacity: 0.55; }
    :host(:state(disabled)) .control, :host(:state(disabled)) .check,
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
    this._syncFormValue();
  }

  /** Show / clear the field's error (called by <work-form>); reflects validity.
   *  The `error` attr drives the Lit `.error` binding; we also write the node's
   *  text synchronously so a read right after setError (before Lit's async flush)
   *  already reflects it. The src/validate result feeds NATIVE constraint
   *  validation here: a message → setValidity({customError:true}, msg, anchorEl)
   *  so the field blocks native <form> submit and reports the same human message
   *  the floor produced; no message → setValidity({}) (valid). The CustomStateSet
   *  + [invalid] attribute both carry the styling. */
  setError(message) {
    if (message) { this.setAttribute("invalid", ""); this.setAttribute("error", message); }
    else { this.removeAttribute("invalid"); this.removeAttribute("error"); }
    this._setState("invalid", !!message);
    if (this._internals && typeof this._internals.setValidity === "function") {
      if (message) this._internals.setValidity({ customError: true }, message, this._controlEl() || undefined);
      else this._internals.setValidity({});
    }
    const el = this.shadowRoot && this.shadowRoot.querySelector(".error");
    if (el) el.textContent = message || "";
  }
  clearError() { this.setError(null); }

  /** Native constraint-validation surface, delegated to ElementInternals so the
   *  field behaves like a built-in input in script and in a real <form>. */
  checkValidity() { return this._internals ? this._internals.checkValidity() : !this.hasAttribute("invalid"); }
  reportValidity() { return this._internals ? this._internals.reportValidity() : !this.hasAttribute("invalid"); }
  get validity() { return this._internals ? this._internals.validity : undefined; }
  get validationMessage() { return this._internals ? this._internals.validationMessage : (this.attr("error") || ""); }
  /** The <form> this field participates in (FACE), when associated. */
  get form() { return this._internals ? this._internals.form : null; }

  /** Push the field's current value into native form submission. Called after
   *  every render and on programmatic value set so `new FormData(form)` carries
   *  this field's value under its `name` with zero manual harvesting. */
  _syncFormValue() {
    if (!this._internals || typeof this._internals.setFormValue !== "function") return;
    const type = (this.attr("type", "text") || "text").toLowerCase();
    const v = this.value;
    // A checkbox submits its value (or "on") only when checked — match the
    // platform: unchecked contributes nothing to the form data.
    if (type === "checkbox") { this._internals.setFormValue(v ? (this.attr("value") || "on") : null); return; }
    this._internals.setFormValue(v == null ? "" : String(v));
  }

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
    // Native form participation: every value change updates what the <form>
    // submits, so the owning <work-form> / a real <form> never harvests the DOM.
    if (kind === "input") this._syncFormValue();
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

  connectedCallback() {
    super.connectedCallback();
    this._syncAuthorStates();
    this._setState("invalid", this.hasAttribute("invalid"));
  }

  // After Lit paints the control, publish the field's value to native form
  // submission (the control element now exists / has its bound value).
  updated(changed) {
    super.updated?.(changed);
    this._syncFormValue();
    // Author may have changed required/disabled between renders — keep states synced.
    this._syncAuthorStates();
  }

  // The browser calls this when an ancestor <fieldset disabled> / form-disabled
  // state toggles — mirror it into our own disabled styling + states.
  formDisabledCallback(disabled) {
    if (disabled) this.setAttribute("disabled", ""); else this.removeAttribute("disabled");
    this._setState("disabled", disabled);
  }

  // Native form reset — clear value + error like a built-in control.
  formResetCallback() {
    this.value = "";
    this.clearError();
  }
}

define("work-field", WbField);
