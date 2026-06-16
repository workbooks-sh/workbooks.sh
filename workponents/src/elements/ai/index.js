// workponents · ai domain — the conversation-as-source element set.
//
// The reinvention: a conversation IS a living markdown/org document the agent
// edits; the thread renders that source (turns = its diff stream), and the UI
// the agent generates is authored INLINE as `#+begin_src component` blocks
// (rendered to <chat-gen-block> cards) — NOT a JSON IR. All four elements style
// only from --work-* tokens, extend WbElement, register via define(), and reach
// capability (real inference) through this.host (the Dock seam).
//
// Tags: <chat-message> · <chat-thread> · <chat-gen-block> · <chat-composer>.
// Import this barrel for the whole ai set, or import a single element file.
export { WbMessage } from "./wb-message.js";
export { WbThread } from "./wb-thread.js";
export { WbGenBlock } from "./wb-gen-block.js";
export { WbComposer } from "./wb-composer.js";

// Shared helpers (also usable standalone by a host wiring its own transport).
export { renderMarkdown, splitComponents, parseKvBody, esc } from "./markdown.js";
