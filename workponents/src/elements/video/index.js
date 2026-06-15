// workponents — video domain barrel.
//
// Themed wrappers over the SHIPPED wavelet player (composition-as-source video:
// the player IS the renderer, preview ≡ render, in-guest encode). Importing
// this file registers the elements (idempotent via define()) and re-exports the
// classes. The wavelet runtime itself is imported lazily by <wb-video> on first
// play, from `runtime-src` (default /wavelet/wavelet-runtime.js) — never bundled.
//
//   import "workponents/src/elements/video/index.js";   // register + use tags
//   import { WbVideo } from ".../video/index.js";        // the class

export { WbVideo } from "./wb-video.js";
export { WbVideoSource } from "./wb-video-source.js";
