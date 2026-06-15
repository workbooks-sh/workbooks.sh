// <wb-thread> — renders a whole conversation. The DOC IS THE TRANSCRIPT:
// conversation-as-source. The agent edits a living org/markdown artifact; the
// thread is the rendered view of it (the turns are its diff stream).
//
// Two source modes (the same document, two encodings):
//   1. Light-DOM <wb-message> children — author the transcript declaratively
//      in HTML; <wb-thread> just lays them out (the children render themselves).
//   2. The `turns` property — an array of {role, name, text} OR an org/markdown
//      string with `* role` headings. Setting it (re)builds <wb-message>s.
//
// Usage:
//   <wb-thread>
//     <wb-message role="user">…</wb-message>
//     <wb-message role="assistant">…</wb-message>
//   </wb-thread>
//
//   el.turns = [{ role: "user", text: "hi" }, { role: "assistant", text: "**hey**" }];
import { WbElement, define } from "../../core/element.js";
import { esc } from "./markdown.js";
import "./wb-message.js";

// `* user` / `* assistant` headings split an org transcript into turns; the
// lines beneath a heading are that turn's source (markdown + component blocks).
const TURN_HEADING = /^\*+\s+(user|assistant|system|tool)\b(.*)$/i;

export class WbThread extends WbElement {
  static props = ["title", "max-width"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .thread {
      display: flex; flex-direction: column; gap: var(--wb-space-5);
      max-width: var(--_mw, 760px); margin: 0 auto;
    }
    .title { font: 700 11px var(--wb-font-mono); letter-spacing: .18em;
      text-transform: uppercase; color: var(--wb-fg-subtle); margin-bottom: var(--wb-space-2); }
    ::slotted(wb-message) { display: block; }
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
    if (this._connected) this.update();
  }
  get turns() {
    return this._turns || null;
  }

  render() {
    const title = this.attr("title");
    const mw = this.attr("max-width");
    const head = title ? `<div class="title">${esc(title)}</div>` : "";
    const style = mw ? ` style="--_mw:${esc(mw)}"` : "";

    // Built mode: render the turns array into <wb-message>s.
    if (this._turns) {
      const msgs = this._turns
        .map((t) => {
          const name = t.name ? ` name="${esc(t.name)}"` : "";
          return `<wb-message role="${esc(t.role || "assistant")}"${name} text="${esc(t.text || "")}"></wb-message>`;
        })
        .join("");
      return `<div class="thread"${style}>${head}<div class="built">${msgs}</div></div>`;
    }

    // Declarative mode: lay out light-DOM <wb-message> children via slot.
    return `<div class="thread"${style}>${head}<slot></slot></div>`;
  }
}

define("wb-thread", WbThread);
