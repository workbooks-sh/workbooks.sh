// Chat-mode backdrop state (demo FIX 3).
//
// When a foreground create-mode chat is active, the GridShader inverts its
// vignette: clear/transparent in the CENTER (behind the conversation) and a
// faint grid only at the EDGES. HomePanel flips `chatBackdrop.active` on when
// the page becomes a thread and off when the chat is cleared; GridShader reads
// it and eases a uniform toward 0/1, so the transition animates both ways.
//
// A module singleton (not a prop) because the shader lives in the root
// +layout while the chat lives deep in HomePanel — they never share a tree.

class ChatBackdrop {
  /** True while the create page is a live conversation. */
  active = $state(false);
}

export const chatBackdrop = new ChatBackdrop();
