// workponents · presentation domain — THE reinvention: a deck IS a wavelet
// timeline and the slides ARE its discrete keyframe bands. Because of that one
// idea the domain shares the wavelet render-core with `video`, so "export to
// video" is free (the deck folds its slides into a <gm-doc> and hands it to the
// SAME encode path <wb-video> uses), and live workponents (a <wb-chart>, a
// <wb-video>) live ON slides as first-class citizens — not screenshots.
//
// Composition-as-source: the ordered <wb-slide> children ARE the deck. Importing
// this barrel registers the elements (idempotent via define()) + re-exports the
// classes. Zero dependencies, no build. The wavelet runtime is only needed for
// export (lazily, via the Host or a portable bundle) — never for viewing.
//
//   import "workponents/src/elements/presentation/index.js"; // register + use tags
//   import { WbDeck } from ".../presentation/index.js";       // the class

export { WbDeck } from "./wb-deck.js";
export { WbSlide } from "./wb-slide.js";
