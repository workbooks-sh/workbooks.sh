// workponents · presentation domain — THE reinvention: a deck IS a wavelet
// timeline and the slides ARE its discrete keyframe bands. Because of that one
// idea the domain shares the wavelet render-core with `video`, so "export to
// video" is free (the deck folds its slides into a <gm-doc> and hands it to the
// SAME encode path <work-video> uses), and live workponents (a <work-chart>, a
// <work-video>) live ON slides as first-class citizens — not screenshots.
//
// Composition-as-source: the ordered <work-slide> children ARE the deck. Importing
// this barrel registers the elements (idempotent via define()) + re-exports the
// classes. The wavelet runtime is only needed for export (lazily, via the Host or
// a portable bundle) — never for viewing. Lit-based; buildless ESM.
//
//   import "workponents/src/elements/presentation/index.js"; // register + use tags
//   import { WorkDeck } from ".../presentation/index.js";     // the class

export { WorkDeck } from "./work-deck.js";
export { WorkSlide } from "./work-slide.js";

// pptx ↔ deck I/O adapter (Phase 4b): export a deck → .pptx, import a .pptx → deck
// source. Floor-JS, lazy CDN (PptxGenJS write / fflate+OOXML read). Slides→video
// stays the deck's own export("video") path — pptx is the Office-format sibling.
export { exportPptx, importPptx, looksLikePptx, PPTX_MIME } from "./pptx-io.js";
