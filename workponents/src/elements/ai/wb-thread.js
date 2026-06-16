// <chat-thread> — renders a whole conversation. The DOC IS THE TRANSCRIPT:
// conversation-as-source. The agent edits a living org/markdown artifact; the
// thread is the rendered view of it (the turns are its diff stream).
//
// Two source modes (the same document, two encodings):
//   1. Light-DOM <chat-message> children — author the transcript declaratively
//      in HTML; <chat-thread> just lays them out (the children render themselves).
//   2. The `turns` property — an array of {role, name, text} OR an org/markdown
//      string with `* role` headings. Setting it (re)builds <chat-message>s.
//
// Usage:
//   <chat-thread>
//     <chat-message role="user">…</chat-message>
//     <chat-message role="assistant">…</chat-message>
//   </chat-thread>
//
//   el.turns = [{ role: "user", text: "hi" }, { role: "assistant", text: "**hey**" }];
import { WbElement, html, css, define } from "../../core/element.js";
import "./wb-message.js";

// `* user` / `* assistant` headings split an org transcript into turns; the
// lines beneath a heading are that turn's source (markdown + component blocks).
const TURN_HEADING = /^\*+\s+(user|assistant|system|tool)\b(.*)$/i;

export class WbThread extends WbElement {
  static props = ["title", "max-width"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .thread {
      display: flex; flex-direction: column; gap: var(--work-space-5);
      max-width: var(--_mw, 760px); margin: 0 auto;
    }
    .title { font: 700 11px var(--work-font-mono); letter-spacing: .18em;
      text-transform: uppercase; color: var(--work-fg-subtle); margin-bottom: var(--work-space-2); }
    ::slotted(chat-message) { display: block; }
    .built { display: contents; }
  `;

  /** Parse an org/markdown transcript string into {role, name, text} turns. */
  static parseTranscript(src) {
    const lines = String(src ?? "").replace(/\r\n?/g, "\n").split("\n");
    const turns = [];
    let cur = null;
    for (const line of lines) {
      const h = line.match(TURN_HEADING);
      if (h) {
        if (cur) turns.push(cur);
        cur = { role: h[1].toLowerCase(), name: h[2].trim() || h[1].toLowerCase(), lines: [] };
      } else if (cur) {
        cur.lines.push(line);
      }
    }
    if (cur) turns.push(cur);
    return turns.map((t) => ({ role: t.role, name: t.name, text: t.lines.join("\n").trim() }));
  }

  /** Set the conversation from an array or an org/markdown transcript string. */
  set turns(value) {
    this._turns = Array.isArray(value) ? value : WbThread.parseTranscript(value);
    if (this._connected) this.requestUpdate();
  }
  get turns() {
    return this._turns || null;
  }

  connectedCallback() {
    this._connected = true;
    super.connectedCallback();
  }

  render() {
    const title = this.attr("title");
    const mw = this.attr("max-width");
    const head = title ? html`<div class="title">${title}</div>` : "";
    const style = mw ? `--_mw:${mw}` : "";

    // Built mode: render the turns array into <chat-message>s.
    if (this._turns) {
      return html`<div class="thread" style=${style}>${head}<div class="built">${this._turns.map(
        (t) => this._message(t),
      )}</div></div>`;
    }

    // Declarative mode: lay out light-DOM <chat-message> children via slot.
    return html`<div class="thread" style=${style}>${head}<slot></slot></div>`;
  }

  /** Build a <chat-message> element, passing text via the property (no escaping). */
  _message(t) {
    const el = document.createElement("chat-message");
    el.setAttribute("role", t.role || "assistant");
    if (t.name) el.setAttribute("name", t.name);
    el.text = t.text || "";
    return el;
  }
}

define("chat-thread", WbThread);
