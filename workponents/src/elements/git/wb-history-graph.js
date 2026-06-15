// <wb-history-graph> — the user-facing History timeline.
//
// The reinvention: version control's log without git's vocabulary. Nodes are
// VERSIONS (never "commits"), each with an author/agent badge and a title; the
// rail draws a Sapling-smartlog-legible spine with branch lanes. Selecting a
// version emits a `selected` CustomEvent {detail:{id, version}} — the host wires
// that to <wb-diff>/<wb-restore>. Data via `items` (JSON array) attr or property.
//
// Each version mirrors the History backend Change shape (history.ex):
//   { id, when, author_type: "human"|"agent", author_name, title, parents? }
import { WbElement, define } from "../../core/element.js";

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

function fmtWhen(w) {
  if (w == null) return "";
  const d = typeof w === "number" ? new Date(w < 1e12 ? w * 1000 : w) : new Date(w);
  if (isNaN(d)) return String(w);
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 604800) return `${Math.floor(diff / 86400)}d ago`;
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export class WbHistoryGraph extends WbElement {
  static props = ["items", "selected"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); font-size: var(--wb-text); color: var(--wb-fg); }
    .frame { border: 1px solid var(--wb-border); border-radius: var(--wb-radius); background: var(--wb-surface); box-shadow: var(--wb-shadow-sm); overflow: hidden; }
    .head { padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border); background: var(--wb-surface-soft); font: 700 10px var(--wb-font-mono); letter-spacing: .14em; text-transform: uppercase; color: var(--wb-fg-subtle); }
    ul { list-style: none; margin: 0; padding: var(--wb-space-2) 0; }
    li { position: relative; display: grid; grid-template-columns: 36px 1fr; align-items: start; cursor: pointer; }
    li:focus-visible { outline: none; }
    li:focus-visible .body { box-shadow: 0 0 0 2px var(--wb-ring); }

    /* the rail: a vertical spine with a node per version */
    .rail { position: relative; display: flex; justify-content: center; }
    .rail::before { content: ""; position: absolute; top: 0; bottom: 0; left: 50%; width: 2px; transform: translateX(-50%); background: var(--wb-border-strong); }
    li:first-child .rail::before { top: 14px; }
    li:last-child  .rail::before { bottom: calc(100% - 14px); }
    .node { position: relative; margin-top: 7px; width: 13px; height: 13px; border-radius: var(--wb-radius-pill); background: var(--wb-surface); border: 2.5px solid var(--wb-border-strong); z-index: 1; transition: border-color var(--wb-dur) var(--wb-ease), background var(--wb-dur) var(--wb-ease), transform var(--wb-dur) var(--wb-ease); }
    li[data-author="agent"] .node { border-color: var(--wb-brand); }
    li.sel .node { background: var(--wb-brand); border-color: var(--wb-brand); transform: scale(1.18); box-shadow: 0 0 0 4px var(--wb-brand-soft); }

    .body { margin: 3px var(--wb-space-3) 3px var(--wb-space-1); padding: var(--wb-space-2) var(--wb-space-3); border-radius: var(--wb-radius-sm); transition: background var(--wb-dur) var(--wb-ease); }
    li:hover .body { background: var(--wb-surface-soft); }
    li.sel .body { background: var(--wb-brand-soft); }
    .title { font-weight: 600; line-height: 1.3; }
    .meta { display: flex; align-items: center; gap: var(--wb-space-2); margin-top: 3px; font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }
    .when { font-variant-numeric: tabular-nums; }
    .id { font-family: var(--wb-font-mono); font-size: 11px; color: var(--wb-fg-subtle); }

    .badge { display: inline-flex; align-items: center; gap: 5px; padding: 1px 8px; border-radius: var(--wb-radius-pill); font-size: 11px; font-weight: 600; }
    .badge .dot { width: 6px; height: 6px; border-radius: var(--wb-radius-pill); }
    .badge.human { background: var(--wb-surface-soft); color: var(--wb-fg-muted); }
    .badge.human .dot { background: var(--wb-fg-subtle); }
    .badge.agent { background: var(--wb-brand-soft); color: var(--wb-brand-ink, var(--wb-brand)); }
    .badge.agent .dot { background: var(--wb-brand); }

    .empty { padding: var(--wb-space-5) var(--wb-space-4); text-align: center; color: var(--wb-fg-subtle); font-size: var(--wb-text-sm); }
  `;

  // items can be a JSON attribute or an assigned property.
  set items(v) { this._items = Array.isArray(v) ? v : null; this.update(); }
  get items() {
    if (this._items) return this._items;
    const raw = this.attr("items");
    if (!raw) return [];
    try { return JSON.parse(raw); } catch { return []; }
  }

  connectedCallback() {
    super.connectedCallback();
    // Listen on the shadow root: clicks inside shadow DOM are retargeted to the
    // host as they bubble out, so a host listener can't resolve the inner <li>.
    this.shadowRoot.addEventListener("click", (e) => {
      const li = e.target.closest("li[data-id]");
      if (li) this._select(li.dataset.id);
    });
    this.shadowRoot.addEventListener("keydown", (e) => {
      const li = e.target.closest("li[data-id]");
      if (li && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); this._select(li.dataset.id); }
    });
  }

  _select(id) {
    this.setAttribute("selected", id);
    const version = this.items.find((v) => String(v.id) === String(id));
    this.dispatchEvent(new CustomEvent("selected", { bubbles: true, composed: true, detail: { id, version } }));
  }

  render() {
    const items = this.items;
    const sel = this.attr("selected");
    if (!items.length) return `<div class="frame"><div class="head">history</div><div class="empty">No versions yet.</div></div>`;
    const rows = items.map((v) => {
      const at = v.author_type === "agent" ? "agent" : "human";
      const isSel = sel != null && String(v.id) === String(sel);
      return `
        <li tabindex="0" role="button" data-id="${esc(v.id)}" data-author="${at}" class="${isSel ? "sel" : ""}" aria-pressed="${isSel}">
          <div class="rail"><span class="node"></span></div>
          <div class="body">
            <div class="title">${esc(v.title || "(untitled version)")}</div>
            <div class="meta">
              <span class="badge ${at}"><span class="dot"></span>${esc(v.author_name || at)}</span>
              <span class="when">${esc(fmtWhen(v.when))}</span>
              <span class="id">${esc(String(v.id).slice(0, 8))}</span>
            </div>
          </div>
        </li>`;
    }).join("");
    return `<div class="frame"><div class="head">history</div><ul part="list">${rows}</ul></div>`;
  }
}

define("wb-history-graph", WbHistoryGraph);
