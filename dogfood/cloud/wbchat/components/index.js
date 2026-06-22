// wbchat components — importing this registers every add-on part renderer against the core.
// Each module calls registerPart(type, fn) at load (side effect). Loaded by the host AFTER core.js,
// so code-hl's 'code' override replaces the core default. Add a new component = one import line here.
import './reasoning.js';   // part: reasoning   (collapsible thinking)
import './tool.js';        // part: tool        (tool-call card)
import './sources.js';     // part: sources     (citations list)
import './media.js';       // parts: image, file
import './code-hl.js';     // part: code        (syntax-highlight override)
import './task.js';        // part: task        (checklist)
import './followups.js';   // part: suggestions (follow-up chips)
import './feedback.js';    // action: thumbs up/down (assistant)
import './attachments.js'; // composer button: file picker
import './transcribe.js';  // composer button: mic (speech-to-text)
import './agent-selector.js'; // composer button: agent dropdown (Studio, locked once session has messages)
import './model-selector.js'; // composer button: model dropdown
