// <wb-field-value> — a typed single-value display, the atom of the records
// domain. Given a value + its WbColType (the `types[j]` off a WbQueryResult), it
// renders the value the way that type should READ: currency / number / percent
// for numerics, a localized date for dates, a check/✕ pill for booleans, an
// anchor for links, a soft chip badge for short categorical strings. Reused
// inside <wb-record> for every field; usable on its own anywhere a single typed
// cell needs to render the same way the table/record do.
//
// Token-only styling; zero deps. The mapping mirrors wb-table's fmt() helper but
// is type-DRIVEN (the record knows each column's type) rather than format-attr
// driven, and renders richer affordances (links/badges/booleans) suited to a
// detail view rather than a dense grid cell.
//
// Usage:
//   <wb-field-value type="number" format="usd" value="1240.5"></wb-field-value>
//   <wb-field-value type="boolean" value="true"></wb-field-value>
//   <wb-field-value type="string" display="badge" value="EMEA"></wb-field-value>
//   <wb-field-value type="string" display="link" value="https://x.y"></wb-field-value>
//
// Attributes:
//   value     the raw value (string form; numbers/bools coerced by type)
//   type      a WbColType: number|integer|string|boolean|date|json (default string)
//   format    numeric format hint: usd|num|pct (only when type is numeric)
//   display   override the chosen renderer: text|badge|link|bool|date|money|json
//   empty     placeholder shown when value is null/empty (default "—")
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  // how the value reads; auto = pick from `type`. Mirrors record field intent.
  display: { options: ["auto", "text", "badge", "link", "bool", "date", "money", "json"], default: "auto" },
});

export class WbFieldValue extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "value", "type", "format", "empty"];

  static styles = `
    :host { display: inline; font-family: var(--wb-font); color: var(--wb-fg); font-size: var(--wb-text); }
    .empty { color: var(--wb-fg-subtle); }
    .num { font-variant-numeric: tabular-nums; }
    a { color: var(--wb-brand); text-decoration: none; border-bottom: 1px solid var(--wb-brand-soft); }
    a:hover { border-bottom-color: var(--wb-brand); }
    .badge { display: inline-flex; align-items: center; padding: 2px var(--wb-space-2);
      border-radius: var(--wb-radius-pill); background: var(--wb-surface-soft);
      border: 1px solid var(--wb-border); font-size: var(--wb-text-sm);
      font-family: var(--wb-font-mono); color: var(--wb-fg-muted); line-height: 1.5; }
    .bool { display: inline-flex; align-items: center; gap: var(--wb-space-1);
      font-size: var(--wb-text-sm); font-weight: 600; }
    .bool .dot { width: 8px; height: 8px; border-radius: var(--wb-radius-pill); }
    .bool.t { color: var(--wb-ok); } .bool.t .dot { background: var(--wb-ok); box-shadow: 0 0 0 3px var(--wb-brand-soft); }
    .bool.f { color: var(--wb-fg-subtle); } .bool.f .dot { background: var(--wb-fg-subtle); }
    .json { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); color: var(--wb-fg-muted);
      white-space: pre-wrap; word-break: break-word; }
  `;

  render() {
    const raw = this.attr("value");
    const empty = this.attr("empty", "—");
    if (raw == null || raw === "") return `<span class="empty">${esc(empty)}</span>`;

    const type = this.attr("type", "string");
    const mode = this._mode(raw, type);

    switch (mode) {
      case "money":
      case "num": {
        const cls = "num";
        return `<span class="${cls}">${esc(fmtNumber(raw, this.attr("format")))}</span>`;
      }
      case "date":
        return `<span>${esc(fmtDate(raw))}</span>`;
      case "bool": {
        const t = isTrue(raw);
        return `<span class="bool ${t ? "t" : "f"}"><span class="dot"></span>${t ? "Yes" : "No"}</span>`;
      }
      case "link": {
        const href = String(raw);
        const label = href.replace(/^https?:\/\//, "").replace(/\/$/, "");
        return `<a href="${esc(href)}" target="_blank" rel="noopener">${esc(label)}</a>`;
      }
      case "badge":
        return `<span class="badge">${esc(raw)}</span>`;
      case "json":
        return `<span class="json">${esc(fmtJson(raw))}</span>`;
      default:
        return `<span>${esc(raw)}</span>`;
    }
  }

  /** Resolve the renderer: explicit `display` wins, else infer from type+value. */
  _mode(raw, type) {
    const d = this.attr("display", "auto");
    if (d && d !== "auto") return d;
    if (type === "boolean") return "bool";
    if (type === "date") return "date";
    if (type === "json") return "json";
    if (type === "number" || type === "integer") {
      return this.attr("format") ? "money" : "num";
    }
    // string: detect a URL → link; otherwise plain text (badge is opt-in).
    if (/^https?:\/\//i.test(String(raw))) return "link";
    return "text";
  }
}

// ── helpers (token-unaware) ───────────────────────────────────────────────────
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
function isTrue(v) {
  if (typeof v === "boolean") return v;
  const s = String(v).trim().toLowerCase();
  return s === "true" || s === "1" || s === "yes" || s === "t";
}
function fmtNumber(v, format) {
  const n = Number(v);
  if (!Number.isFinite(n)) return String(v);
  if (format === "usd") return "$" + n.toLocaleString(undefined, { maximumFractionDigits: 2 });
  if (format === "pct") return (n * (Math.abs(n) <= 1 ? 100 : 1)).toFixed(1) + "%";
  if (format === "num") return n.toLocaleString();
  return Number.isInteger(n) ? n.toLocaleString() : n.toLocaleString(undefined, { maximumFractionDigits: 4 });
}
function fmtDate(v) {
  let d;
  if (v instanceof Date) d = v;
  else if (typeof v === "number") d = new Date(v);
  else {
    const s = String(v).trim();
    // A bare integer string is an epoch (ms if 13 digits, else seconds) — this is
    // how DuckDB hands back a DATE column through the numeric engine mapping.
    if (/^-?\d+$/.test(s)) { const n = Number(s); d = new Date(s.length > 11 ? n : n * 1000); }
    else d = new Date(s);
  }
  if (isNaN(d.getTime())) return String(v);
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}
function fmtJson(v) {
  if (typeof v === "string") {
    try { return JSON.stringify(JSON.parse(v), null, 2); } catch { return v; }
  }
  try { return JSON.stringify(v, null, 2); } catch { return String(v); }
}

define("wb-field-value", WbFieldValue);
