// <deck-slide> — one slide of a <deck-view>. The reinvention (per the presentation
// brief): a deck IS a wavelet timeline and each slide is a discrete KEYFRAME BAND
// on it. A <deck-slide> therefore carries, as source, the description of its band
// (how long it holds, how it enters) — the same data the deck folds into a
// <gm-doc> timeline when you export() to video. Preview ≡ render ≡ the band.
//
// Composition-as-source: the slotted content IS the slide. It stays in the LIGHT
// DOM (default <slot>) so any other workponent placed inside — a <chart-view>, a
// <video-player>, a <grid-table> — upgrades and renders exactly as it would anywhere
// else. The shadow root only paints a themed frame from --work-* tokens; it never
// re-renders or owns the author's content.
//
// The deck drives visibility: it sets/removes the boolean `active` attribute (and
// `prev`/`next` for peek affordances). A slide never decides on its own which one
// is showing — the deck is the single source of the playhead.
//
// Usage:
//   <deck-view>
//     <deck-slide band="title" transition="fade" hold="3s">
//       <h1>Workponents</h1><p>One substrate, many domains.</p>
//     </deck-slide>
//     <deck-slide transition="rise">
//       <chart-view type="bar" rows='[…]' x="region" y="rev"></chart-view>
//     </deck-slide>
//   </deck-view>
//
// Attributes:
//   band         a semantic label for the keyframe band (title|content|media|
//                closing|… ) — drives default layout + is carried into export.
//   transition   how the band ENTERS: fade | rise | slide | scale | none.
//   hold         band duration for video export (e.g. "4s", "120f"); deck default
//                applies when unset. Live nav ignores it (advance is manual).
//   align        content alignment within the slide: center | start | end.
//   active       (set by the deck) this slide is the current playhead band.
//   prev / next  (set by the deck) adjacency hints for peek/transition direction.
//
// Events: none of its own — the deck owns work-slide-change. A slide exposes
// `band` / `transition` / `hold` as properties for the deck's export folder.

import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs, resolveVariant } from "../../core/variants.js";

const VARIANTS = defineVariants({
  // semantic band — also the default layout preset for the slide
  band: { options: ["title", "content", "media", "split", "quote", "closing"], default: "content" },
  // how the band enters when it becomes active
  transition: { options: ["fade", "rise", "slide", "scale", "none"], default: "fade" },
  // content alignment within the frame
  align: { options: ["center", "start", "end"], default: "center" },
});

export class WorkSlide extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "active", "prev", "next", "hold"];

  static styles = css`
    :host {
      display: none;                /* deck shows exactly one band at a time */
      position: absolute; inset: 0;
      box-sizing: border-box;
      color: var(--work-fg);
      font-family: var(--work-font);
    }
    :host([active]) { display: block; }

    .band {
      position: absolute; inset: 0;
      display: flex; flex-direction: column;
      gap: var(--work-space-4);
      padding: clamp(28px, 6vw, 80px);
      overflow: auto;
    }
    /* alignment */
    :host([align="center"]) .band { align-items: center; justify-content: center; text-align: center; }
    :host([align="start"])  .band { align-items: flex-start; justify-content: center; text-align: left; }
    :host([align="end"])    .band { align-items: flex-end; justify-content: flex-end; text-align: right; }

    /* band presets — typographic scale for the slotted content, tokens only */
    ::slotted(h1) { font-family: var(--work-font-display, var(--work-font)); font-weight: 600; letter-spacing: -.02em; margin: 0; line-height: 1.04; }
    ::slotted(h2) { font-family: var(--work-font-display, var(--work-font)); font-weight: 600; letter-spacing: -.01em; margin: 0; line-height: 1.1; }
    ::slotted(p)  { color: var(--work-fg-muted); margin: 0; max-width: 64ch; line-height: 1.5; }
    ::slotted(ul), ::slotted(ol) { color: var(--work-fg); margin: 0; line-height: 1.7; max-width: 60ch; }

    :host([band="title"]) ::slotted(h1) { font-size: clamp(40px, 8vw, 92px); }
    :host([band="title"]) ::slotted(p)  { font-size: var(--work-text-lg); color: var(--work-fg-muted); }
    :host([band="content"]) ::slotted(h2) { font-size: clamp(26px, 4.5vw, 48px); }
    :host([band="quote"]) ::slotted(blockquote) {
      font-family: var(--work-font-display, var(--work-font));
      font-size: clamp(24px, 4vw, 44px); line-height: 1.3; margin: 0; max-width: 22ch;
      color: var(--work-fg); border: none; padding: 0;
    }
    :host([band="media"]) .band { padding: clamp(16px, 3vw, 36px); }
    :host([band="media"]) ::slotted(*) { width: 100%; max-width: min(100%, 1100px); }

    /* split: two stacked/side-by-side regions via the named slots */
    :host([band="split"]) .band { display: grid; gap: var(--work-space-5);
      grid-template-columns: 1fr 1fr; align-content: center; text-align: left; }
    @media (max-width: 680px) { :host([band="split"]) .band { grid-template-columns: 1fr; } }

    /* enter transitions — only run when the band becomes active */
    :host([active]) .band { animation: fade-in var(--work-deck-enter, .42s) var(--work-ease) both; }
    :host([active][transition="none"]) .band { animation: none; }
    :host([active][transition="fade"])  .band { animation-name: fade-in; }
    :host([active][transition="rise"])  .band { animation-name: rise-in; }
    :host([active][transition="slide"]) .band { animation-name: slide-in; }
    :host([active][transition="scale"]) .band { animation-name: scale-in; }

    @keyframes fade-in  { from { opacity: 0; } to { opacity: 1; } }
    @keyframes rise-in  { from { opacity: 0; transform: translateY(26px); } to { opacity: 1; transform: none; } }
    @keyframes slide-in { from { opacity: 0; transform: translateX(40px);  } to { opacity: 1; transform: none; } }
    @keyframes scale-in { from { opacity: 0; transform: scale(.94);        } to { opacity: 1; transform: none; } }

    @media (prefers-reduced-motion: reduce) {
      :host([active]) .band { animation: none; }
    }
  `;

  // typed accessors the deck's export folder reads
  get band() { return resolveVariant(this, VARIANTS, "band"); }
  get transition() { return resolveVariant(this, VARIANTS, "transition"); }
  get hold() { return this.attr("hold"); }

  render() {
    // band="split" exposes two regions; otherwise one default slot. Either way
    // the author's content stays in the light DOM and renders as itself.
    if (resolveVariant(this, VARIANTS, "band") === "split") {
      return html`<div class="band"><div class="region"><slot name="a"></slot></div><div class="region"><slot name="b"></slot></div></div>`;
    }
    return html`<div class="band"><slot></slot></div>`;
  }
}

define("deck-slide", WorkSlide);
