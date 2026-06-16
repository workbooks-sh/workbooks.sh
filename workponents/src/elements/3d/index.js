// workponents — 3d domain barrel.
//
// Themed wrappers over Google's <model-viewer> (Apache-2.0, three.js-based) for
// glTF/GLB/STL, plus the composition-as-source-for-3D descriptor. The viewer
// engine is imported lazily from a CDN on first connect — never bundled, no dep
// installed (mirrors the video / data-viz lazy-load lane). Importing this file
// registers the elements (idempotent via define()) and re-exports the classes.
//
//   import "workponents/src/elements/3d/index.js";   // register + use tags
//   import { WorkModel } from ".../3d/index.js";      // the class
//
// Generation (text/image → 3D) is HOST-BROKERED (Meshy/Tripo via this.host) — see
// WorkModel.generate(); the seam is documented, no live key is wired.

export { WorkModel } from "./work-model.js";
export { WorkModelSource, loadManifold } from "./work-model-source.js";
