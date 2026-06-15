// <wb-video-source> — a declarative source descriptor for <wb-video>, the
// composition-as-source analogue of <source> inside <video>.
//
// It renders NOTHING itself; it is a typed slot of metadata the parent
// <wb-video> reads to resolve what to play, so authors can express the source
// declaratively instead of as attributes:
//
//   <wb-video controls>
//     <wb-video-source composition="<gm-doc …>…</gm-doc>"></wb-video-source>
//   </wb-video>
//
//   <wb-video controls>
//     <wb-video-source src="reel.html" type="wavelet/composition"></wb-video-source>
//   </wb-video>
//
// `src`         — URL of a wavelet composition (.html) to fetch.
// `composition` — inline composition markup (a <gm-doc> tree); preferred,
//                 keeps the artifact its own source (no fetch).
// `type`        — advisory MIME-ish hint (default "wavelet/composition").
//
// Resolution precedence lives in <wb-video>: an inline `composition` (here or
// on the parent, or a slotted <gm-doc>) wins over a fetched `src`.

import { WbElement, define } from "../../core/element.js";

export class WbVideoSource extends WbElement {
  static props = ["src", "composition", "type"];
  // No visible rendering — this is metadata for the parent <wb-video>.
  static styles = `:host { display: none; }`;

  /** The source descriptor the parent reads. */
  get descriptor() {
    return {
      src: this.attr("src"),
      composition: this.attr("composition"),
      type: this.attr("type", "wavelet/composition"),
    };
  }

  // When the descriptor changes, ask the parent <wb-video> to re-resolve.
  attributeChangedCallback(name, oldV, newV) {
    super.attributeChangedCallback?.(name, oldV, newV);
    if (this._connected && oldV !== newV) {
      const parent = this.closest("wb-video");
      parent?._boot?.();
    }
  }

  render() {
    return "";
  }
}

define("wb-video-source", WbVideoSource);
