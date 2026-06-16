// <form-view> — the form surface. THE reinvention: a form IS its schema. The form
// owns one declarative schema (inline JSON `schema` attr/property, OR built from
// its child <form-field> rules), runs `src/validate` against the live values on
// input + on submit, blocks submit while invalid, and writes errors back down to
// each field — validation is never hand-wired per control. Themed entirely from
// --work-* tokens.
//
// Events:
//   work-submit  { detail: { values } }  — fired only when the record is valid
//   work-invalid { detail: { errors } }  — fired when a submit is blocked
//   work-change  { detail: { values, valid } } — on every field input (live)
//
// Standalone (sync floor) by default; when a Host with a /validate route is
// reachable (this.host.available("validate")) it merges server/derived errors
// on submit via validateRecordAsync — the floor stays authoritative for what it
// can decide, the Host only adds what it alone knows (uniqueness, cross-record).
//
// Usage:
//   <form-view>
//     <form-field name="email" type="email" label="Email" required></form-field>
//     <form-field name="pw" type="password" label="Password" required min="8"></form-field>
//     <wb-button type="submit" slot="actions">Create</wb-button>
//   </form-view>
import { WbElement, html, css, define } from "../../core/element.js";
import { validateRecord, validateRecordAsync, parseSchema } from "../../validate/index.js";

export class WbForm extends WbElement {
  static props = ["schema", "submit-label", "novalidate", "live"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    form { display: block; }
    .fields { display: block; }
    .actions { display: flex; gap: var(--work-space-3); align-items: center; margin-top: var(--work-space-4); }
    .summary { margin: 0 0 var(--work-space-4); padding: var(--work-space-3) var(--work-space-4);
      border-radius: var(--work-radius); background: var(--work-err-faint);
      border: 1px solid var(--work-err); color: var(--work-err); font-size: var(--work-text-sm);
      font-weight: 500; line-height: 1.5; display: none; }
    :host([invalid]) .summary[data-has] { display: block; }
    .submit { font: 600 var(--work-text) var(--work-font); padding: var(--work-space-3) var(--work-space-5);
      border-radius: var(--work-radius); border: 1.5px solid transparent;
      background: var(--work-brand); color: var(--work-on-brand); cursor: pointer;
      transition: transform var(--work-dur) var(--work-ease), box-shadow var(--work-dur) var(--work-ease); }
    .submit:hover { transform: translateY(-1px); }
    .submit:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    .submit[disabled] { opacity: 0.5; pointer-events: none; }
  `;

  /** The form's schema — explicit property/attr wins; otherwise built from the
   *  child <form-field> rules (the form IS its schema). */
  get schema() {
    if (this._schema) return this._schema;
    const attr = this.attr("schema");
    if (attr) { try { return parseSchema(JSON.parse(attr)); } catch { /* fall through */ } }
    return this._schemaFromFields();
  }
  set schema(v) { this._schema = v; }

  _fields() {
    return Array.from(this.querySelectorAll("form-field"));
  }

  _schemaFromFields() {
    const s = {};
    for (const f of this._fields()) {
      const name = f.getAttribute("name");
      if (name && f.rule) s[name] = f.rule;
    }
    return s;
  }

  /** The native <form> the fields actually participate in. A Form-Associated
   *  Custom Element associates with the nearest ANCESTOR <form> in its own tree —
   *  the <form-field>s live in this element's light DOM, so that is the <form>
   *  the author wraps <form-view> in (`<form><form-view>…`). The inner shadow
   *  <form> is layout/submit-affordance only and is NOT where slotted fields
   *  associate, so we read the owning light-DOM form for native participation. */
  get _ownerForm() {
    return this.closest("form");
  }

  /** The owning form's native FormData — the fields' submitted values (FACE).
   *  Proves native participation: each field appears here under its `name`
   *  because it called setFormValue, with NO manual DOM harvesting. Empty when
   *  <form-view> is not wrapped in a real <form> (standalone usage). */
  formData() {
    const form = this._ownerForm;
    return form && typeof FormData === "function" ? new FormData(form) : new FormData();
  }

  /** Current { name: typed-value } record for the schema floor. The validate
   *  layer needs TYPED values (number→number, checkbox→boolean) and the presence
   *  of empty fields to fire `required`; native FormData yields only strings and
   *  drops unchecked checkboxes, so the typed record is read from each field's
   *  `value` (the same value the field published to the form via setFormValue).
   *  `formData()` exposes the raw native submission separately. */
  get values() {
    const out = {};
    for (const f of this._fields()) {
      const name = f.getAttribute("name");
      if (name) out[name] = f.value;
    }
    return out;
  }

  render() {
    const label = this.attr("submit-label", "Submit");
    return html`
      <form novalidate @submit=${this._onSubmit}>
        <p class="summary" role="alert"></p>
        <div class="fields"><slot></slot></div>
        <div class="actions">
          <slot name="actions"><button class="submit" type="submit">${label}</button></slot>
        </div>
      </form>`;
  }

  connectedCallback() {
    super.connectedCallback();

    // Live validation: any field input bubbles work-field-input / work-field-blur.
    this.addEventListener("work-field-input", (e) => {
      this.dispatchEvent(new CustomEvent("work-change", {
        bubbles: true, composed: true,
        detail: { values: this.values, valid: validateRecord(this.values, this.schema).valid },
      }));
      // Re-validate just the touched field if it currently shows an error (clear-on-fix),
      // or always when `live` is set.
      const touched = e.detail && e.detail.name;
      if (this.boolAttr("live") || this._submitted || this._fieldInvalid(touched)) this._revalidateField(touched);
    });
    this.addEventListener("work-field-blur", (e) => {
      if (this._submitted || this.boolAttr("live")) this._revalidateField(e.detail && e.detail.name);
    });

    // A slotted action button might be a <wb-button> not a real submit; catch clicks.
    this.addEventListener("click", (e) => {
      const t = e.target;
      const tag = t && t.tagName && t.tagName.toLowerCase();
      if ((tag === "wb-button" || (t && t.getAttribute && t.getAttribute("type") === "submit")) &&
          (t.slot === "actions" || t.getAttribute("slot") === "actions")) {
        e.preventDefault(); this.submit();
      }
    });

    // Native form participation: when the author wraps <form-view> in a real
    // <form>, the child <form-field>s are Form-Associated to THAT form. Run the
    // schema floor on the owning form's native submit so the floor's errors flow
    // into each field's native validity (setValidity via setError) and the
    // browser blocks the submit on any invalid field — the floor and native
    // constraint validation are one path, not two. The work-submit/work-invalid
    // events fire exactly as before (via submit()).
    const owner = this._ownerForm;
    if (owner && !owner.__workFormBound) {
      owner.__workFormBound = true;
      owner.addEventListener("submit", (e) => {
        // submit() seeds field validity from the floor; if anything is invalid the
        // native submit must not proceed.
        this.submit();
        if (this._fields().some((f) => f.hasAttribute("invalid"))) e.preventDefault();
      });
    }
  }

  // Native submit from a slotted real <button type=submit> or the default.
  _onSubmit(e) { e.preventDefault(); this.submit(); }

  _fieldByName(name) {
    return this._fields().find((f) => f.getAttribute("name") === name);
  }
  _fieldInvalid(name) {
    const f = this._fieldByName(name);
    return f && f.hasAttribute("invalid");
  }

  /** Validate one field and write/clear its error (live path). */
  _revalidateField(name) {
    if (!name) return;
    const schema = this.schema;
    const rule = schema[name];
    if (!rule) return;
    const { errors } = validateRecord(this.values, { [name]: rule });
    const f = this._fieldByName(name);
    if (f) f.setError(errors.length ? errors[0].message : null);
    this._refreshSummary();
  }

  /** Apply a full error list down to the fields + the summary. */
  _applyErrors(errors) {
    const byField = {};
    for (const e of errors) { if (!byField[e.path]) byField[e.path] = e.message; }
    for (const f of this._fields()) {
      const name = f.getAttribute("name");
      f.setError(byField[name] || null);
    }
    if (errors.length) this.setAttribute("invalid", ""); else this.removeAttribute("invalid");
    this._refreshSummary(errors);
  }

  _refreshSummary(errors) {
    const sum = this.shadowRoot && this.shadowRoot.querySelector(".summary");
    if (!sum) return;
    const list = errors || this._fields()
      .filter((f) => f.hasAttribute("invalid"))
      .map((f) => ({ message: f.getAttribute("error") }));
    if (list.length) {
      sum.setAttribute("data-has", "");
      sum.textContent = list.length === 1
        ? list[0].message
        : `${list.length} fields need attention.`;
    } else {
      sum.removeAttribute("data-has");
      sum.textContent = "";
    }
  }

  /** Run validation; on valid → work-submit, on invalid → work-invalid + mark fields. */
  async submit() {
    this._submitted = true;
    const values = this.values;
    const schema = this.schema;
    if (this.boolAttr("novalidate")) {
      this.dispatchEvent(new CustomEvent("work-submit", { bubbles: true, composed: true, detail: { values } }));
      return { valid: true, values };
    }
    // Sync floor first (instant), then optional Host merge.
    let result = validateRecord(values, schema);
    this._applyErrors(result.errors);
    if (!result.valid) {
      this.dispatchEvent(new CustomEvent("work-invalid", { bubbles: true, composed: true, detail: { errors: result.errors } }));
      return result;
    }
    // Floor passed — consult the Host for server/derived errors when reachable.
    const merged = await validateRecordAsync(values, schema, this.host);
    if (!merged.valid) {
      this._applyErrors(merged.errors);
      this.dispatchEvent(new CustomEvent("work-invalid", { bubbles: true, composed: true, detail: { errors: merged.errors } }));
      return merged;
    }
    this.removeAttribute("invalid");
    this._refreshSummary([]);
    this.dispatchEvent(new CustomEvent("work-submit", { bubbles: true, composed: true, detail: { values } }));
    return { valid: true, values };
  }

  /** Programmatic validate without firing submit (useful for records/tables). */
  validate() {
    const r = validateRecord(this.values, this.schema);
    this._applyErrors(r.errors);
    return r;
  }

  reset() {
    this._submitted = false;
    for (const f of this._fields()) { f.value = ""; f.clearError(); }
    this.removeAttribute("invalid");
    this._refreshSummary([]);
  }
}

define("form-view", WbForm);
