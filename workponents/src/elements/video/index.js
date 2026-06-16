// workponents — video domain barrel.
//
// Themed wrappers over the SHIPPED wavelet player (composition-as-source video:
// the player IS the renderer, preview ≡ render, in-guest encode). Importing
// this file registers the elements (idempotent via define()) and re-exports the
// classes. The wavelet runtime itself is imported lazily by <work-video> on first
// play, from `runtime-src` (default /wavelet/wavelet-runtime.js) — never bundled.
//
//   import "workponents/src/elements/video/index.js";   // register + use tags
//   import { WorkVideo } from ".../video/index.js";      // the class

export { WorkVideo } from "./wb-video.js";
export { WorkVideoSource } from "./wb-video-source.js";
