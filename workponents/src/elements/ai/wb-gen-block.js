// <wb-gen-block> — an inline component block the agent emits inside a turn.
// Ported from desktop/src/lib/chat/ChatComponent.svelte. The agent authors
// these as `#+begin_src component :type <t> …` blocks in the living document;
// they render as themed cards reading STRUCTURED props/body — never raw LLM
// HTML. This is the "generated UI in the document" surface: NOT a JSON IR,
// the block IS the source.
//
// Types: callout (info/warn/ok/error banner) · kv (key/value table) ·
//        button (action; fires wb-intent) · link (themed external link) ·
//        share (member chips + invite button; fires wb-intent).
// Unknown types fall back to a labeled code block so nothing vanishes.
//
// Usage (props as attributes; body via textContent):
//   <wb-gen-block type="callout" tone="warn" title="Heads up">…body…</wb-gen-block>
//
// Interactive blocks emit a `wb-intent` CustomEvent (bubbles, composed) the
// thread / host can observe — they never execute LLM-authored code.
import { WbElement, define } from "../../core/element.js";
import { esc, parseKvBody } from "./markdown.js";

const ICONS = {
  info: "M12 17v-5m0-4h.01M12 22a10 10 0 100-20 10 10 0 000 20z",
  warn: "M12 9v4m0 4h.01M10.3 3.9 1.8 18a2 2 0 001.7 3h17a2 2 0 001.7-3L14.7 3.9a2 2 0 00-3.4 0z",
  ok: "M22 11.1V12a10 10 0 11-5.9-9.1M22 4 12 14.01l-3-3",
  err: "M12 22a10 10 0 100-20 10 10 0 000 20zM15 9l-6 6m0-6 6 6",
  send: "M22 2 11 13M22 2l-7 20-4-9-9-4 20-7z",
  out: "M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6M15 3h6v6M10 14 21 3",
  users: "M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2M9 11a4 4 0 100-8 4 4 0 000 8m14 10v-2a4 4 0 00-3-3.87M16 3.13A4 4 0 0116 11",
};

function svg(d) {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
}

export class WbGenBlock extends WbElement {
  static props = ["type", "tone", "title", "label", "href", "action", "target", "done"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .card {
      border-radius: var(--wb-radius);
      font-size: var(--wb-text);
      line-height: 1.5;
      max-width: 720px;
    }
    .icon { width: 15px; height: 15px; flex: none; }

    /* callout */
    .callout { display: flex; gap: var(--wb-space-2); padding: var(--wb-space-3) var(--wb-space-4);
      border: 1px solid var(--wb-border); background: var(--wb-surface); }
    .callout .icon { margin-top: 2px; color: var(--wb-fg-muted); }
    .ctitle { font-weight: 600; margin-bottom: 2px; }
    .ctext { white-space: pre-wrap; word-break: break-word; }
    :host([tone="warn"]) .callout { border-color: color-mix(in srgb, var(--wb-warn) 40%, transparent); background: color-mix(in srgb, var(--wb-warn) 7%, var(--wb-surface)); }
    :host([tone="warn"]) .callout .icon { color: var(--wb-warn); }
    :host([tone="ok"]) .callout   { border-color: color-mix(in srgb, var(--wb-ok) 40%, transparent); background: color-mix(in srgb, var(--wb-ok) 7%, var(--wb-surface)); }
    :host([tone="ok"]) .callout .icon { color: var(--wb-ok); }
    :host([tone="error"]) .callout,
    :host([tone="err"]) .callout  { border-color: color-mix(in srgb, var(--wb-err) 40%, transparent); background: color-mix(in srgb, var(--wb-err) 7%, var(--wb-surface)); }
    :host([tone="error"]) .callout .icon,
    :host([tone="err"]) .callout .icon { color: var(--wb-err); }

    /* kv table */
    .kv { border: 1px solid var(--wb-border); background: var(--wb-surface); overflow: hidden; }
    .kvtitle { padding: var(--wb-space-2) var(--wb-space-3); font-weight: 600;
      border-bottom: 1px solid var(--wb-border); background: var(--wb-surface-soft); }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: var(--wb-space-2) var(--wb-space-3);
      border-bottom: 1px solid var(--wb-border); vertical-align: top; }
    tr:last-child th, tr:last-child td { border-bottom: 0; }
    th { width: 38%; color: var(--wb-fg-muted); font-weight: 500;
      font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); }

    /* button / link / share — interactive */
    .btn {
      display: inline-flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-4);
      border: 0; border-radius: var(--wb-radius-sm);
      background: var(--wb-brand); color: var(--wb-on-brand);
      font: 600 var(--wb-text) var(--wb-font); cursor: pointer;
      transition: filter var(--wb-dur) var(--wb-ease), background var(--wb-dur) var(--wb-ease);
    }
    .btn:hover { filter: brightness(1.06); }
    .btn:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    .btn[data-done] { background: var(--wb-brand-soft); color: var(--wb-fg); cursor: default; }
    .btn .icon { width: 14px; height: 14px; }

    .link {
      display: inline-flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3);
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      background: var(--wb-surface); color: var(--wb-brand);
      font: 500 var(--wb-text) var(--wb-font); text-decoration: none; width: fit-content;
    }
    .link:hover { border-color: var(--wb-border-strong); }
    .link .icon { width: 13px; height: 13px; }

    .share { display: flex; flex-direction: column; gap: var(--wb-space-3);
      padding: var(--wb-space-3) var(--wb-space-4);
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius); background: var(--wb-surface); }
    .shead { display: inline-flex; align-items: center; gap: var(--wb-space-2); font-weight: 600; }
    .shead .icon { color: var(--wb-fg-muted); }
    .starget { font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }
    .members { display: flex; align-items: center; gap: var(--wb-space-1); flex-wrap: wrap; }
    .member { display: inline-grid; place-items: center; width: 26px; height: 26px;
      border-radius: 50%; background: var(--wb-brand-soft); color: var(--wb-fg);
      font-size: 10px; font-weight: 700; border: 1px solid var(--wb-border); }
    .mcount { margin-left: var(--wb-space-1); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }

    /* unknown fallback */
    .unknown { border: 1px dashed var(--wb-border-strong); background: var(--wb-surface-soft);
      padding: var(--wb-space-3) var(--wb-space-3); }
    .ulabel { font-size: 10.5px; text-transform: uppercase; letter-spacing: .06em;
      color: var(--wb-fg-subtle); margin-bottom: var(--wb-space-1); }
    pre { margin: 0; white-space: pre-wrap; font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); }
  `;

  /** The raw block body (light-DOM textContent). */
  get body() {
    return (this.textContent || "").trim();
  }

  /** Fire a sideband intent the thread/host observes; mark done. */
  _fire(action, detail = {}) {
    this.setAttribute("done", "");
    this.dispatchEvent(
      new CustomEvent("wb-intent", {
        bubbles: true,
        composed: true,
        detail: { action, ...detail },
      }),
    );
  }

  connectedCallback() {
    super.connectedCallback();
    if (!this._wired) {
      this._wired = true;
      this.shadowRoot.addEventListener("click", (e) => {
        const btn = e.target.closest("[data-fire]");
        if (!btn) return;
        const t = this.attr("type", "callout");
        const target = parseKvBody(this.body).find(([k]) => k === "target")?.[1] || this.attr("target", "");
        if (t === "share") {
          const f = Object.fromEntries(parseKvBody(this.body));
          const members = (f.members || "").split(",").map((m) => m.trim()).filter(Boolean);
          this._fire("share", { target: f.target, members, role: f.role });
        } else {
          this._fire(this.attr("action", "button"), {
            label: this.attr("label", this.body),
            target,
          });
        }
        this.update();
      });
    }
  }

  render() {
    const type = this.attr("type", "callout");
    const tone = this.attr("tone", "info");
    const title = this.attr("title");
    const body = this.body;
    const done = this.boolAttr("done");

    if (type === "kv") {
      const rows = parseKvBody(body)
        .map(([k, v]) => `<tr><th>${esc(k)}</th><td>${esc(v)}</td></tr>`)
        .join("");
      return `<div class="card kv">${title ? `<div class="kvtitle">${esc(title)}</div>` : ""}<table><tbody>${rows}</tbody></table></div>`;
    }

    if (type === "button") {
      const label = done ? this.attr("doneLabel", "Done") : this.attr("label", body || "Run");
      return `<button class="card btn" data-fire ${done ? "data-done" : ""}>${svg(done ? ICONS.ok : ICONS.send)}<span>${esc(label)}</span></button>`;
    }

    if (type === "link") {
      const href = this.attr("href", "#");
      const safe = /^(https?:\/\/|mailto:|\/)/i.test(href) ? href : "#";
      return `<a class="card link" href="${esc(safe)}" target="_blank" rel="noopener noreferrer">${svg(ICONS.out)}<span>${esc(this.attr("label", body || href))}</span></a>`;
    }

    if (type === "share") {
      const f = Object.fromEntries(parseKvBody(body));
      const members = (f.members || "").split(",").map((m) => m.trim()).filter(Boolean);
      const chips = members
        .map((m) => `<span class="member" title="${esc(m)}">${esc(m.split(" ").map((w) => w[0]).join("").slice(0, 2).toUpperCase())}</span>`)
        .join("");
      const count = members.length
        ? `<span class="mcount">${members.length} people · ${esc(f.role || "Editor")}</span>`
        : "";
      return `<div class="card share">
        <div class="shead">${svg(ICONS.users)}<span>${esc(title || "Share with your org")}</span></div>
        ${f.target ? `<div class="starget">${esc(f.target)}</div>` : ""}
        ${members.length ? `<div class="members">${chips}${count}</div>` : ""}
        <button class="btn" data-fire ${done ? "data-done" : ""}>${svg(done ? ICONS.ok : ICONS.send)}<span>${done ? "Invited" : "Send invite"}</span></button>
      </div>`;
    }

    if (type === "callout") {
      const ic = tone === "warn" ? ICONS.warn : tone === "ok" ? ICONS.ok : (tone === "error" || tone === "err") ? ICONS.err : ICONS.info;
      return `<div class="card callout"><span class="icon">${svg(ic)}</span><div>${title ? `<div class="ctitle">${esc(title)}</div>` : ""}<div class="ctext">${esc(body)}</div></div></div>`;
    }

    return `<div class="card unknown"><div class="ulabel">component: ${esc(type)}</div><pre>${esc(body)}</pre></div>`;
  }
}

define("wb-gen-block", WbGenBlock);
