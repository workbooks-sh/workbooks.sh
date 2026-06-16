// <work-video-source> — a declarative source descriptor for <work-video>, the
// composition-as-source analogue of <source> inside <video>.
//
// It renders NOTHING itself; it is a typed slot of metadata the parent
// <work-video> reads to resolve what to play, so authors can express the source
// declaratively instead of as attributes:
//
//   <work-video controls>
//     <work-video-source composition="<gm-doc …>…</gm-doc>"></work-video-source>
//   </work-video>
//
//   <work-video controls>
//     <work-video-source src="reel.html" type="wavelet/composition"></work-video-source>
//   </work-video>
//
// `src`         — URL of a wavelet composition (.html) to fetch.
// `composition` — inline composition markup (a <gm-doc> tree); preferred,
//                 keeps the artifact its own source (no fetch).
// `type`        — advisory MIME-ish hint (default "wavelet/composition").
//
// Resolution precedence lives in <work-video>: an inline `composition` (here or
// on the parent, or a slotted <gm-doc>) wins over a fetched `src`.

import { WbElement, html, css, define } from "../../core/element.js";

export class WorkVideoSource extends WbElement {
  static props = ["src", "composition", "type"];
  // No visible rendering — this is metadata for the parent <work-video>.
  static styles = css`:host { display: none; }`;

  /** The source descriptor the parent reads. */
  get descriptor() {
    return {
      src: this.attr("src"),
      composition: this.attr("composition"),
      type: this.attr("type", "wavelet/composition"),
    };
  }

  // When the descriptor changes, ask the parent <work-video> to re-resolve.
  attributeChangedCallback(name, oldV, newV) {
    super.attributeChangedCallback?.(name, oldV, newV);
    if (this.isConnected && oldV !== newV) {
      const parent = this.closest("work-video");
      parent?._boot?.();
    }
  }

  render() {
    return html``;
  }
}

define("work-video-source", WorkVideoSource);
