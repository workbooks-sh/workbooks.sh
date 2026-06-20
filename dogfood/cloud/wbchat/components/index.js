// wbchat components — importing this registers every add-on part renderer against the core.
// Each module calls registerPart(type, fn) at load (side effect). Loaded by the host AFTER core.js,
// so code-hl's 'code' override replaces the core default. Add a new component = one import line here.
import './reasoning.js';   // part: reasoning   (collapsible thinking)
import './tool.js';        // part: tool        (tool-call card)
import './sources.js';     // part: sources     (citations list)
import './media.js';       // parts: image, file
import './code-hl.js';     // part: code        (syntax-highlight override)
