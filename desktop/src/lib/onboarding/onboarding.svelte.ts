// Onboarding reveal state (wb-aakl.20). Shared so the REAL shell pieces
// (Titlebar, Sidebar, main content, the agent badge) reveal one at a time
// as the coach advances — onboarding is a tutorial of the actual UI, not a
// mock. When inactive (normal app), everything shows.
//
// reveal() MUTATES the reactive record in place (no read-modify-write of the
// whole object) and is driven IMPERATIVELY from the coach's navigation, never
// from a tracked $effect — that read+write-same-state pattern is what froze
// the app last time (effect_update_depth_exceeded).

type Part = "titlebar" | "bench" | "sidebar" | "canvas" | "agent";

class Onboarding {
  active = $state(false);
  #revealed = $state<Record<Part, boolean>>({
    titlebar: false,
    bench: false,
    sidebar: false,
    canvas: false,
    agent: false,
  });

  start(): void {
    this.active = true;
  }

  reveal(...parts: Part[]): void {
    for (const p of parts) {
      if (!this.#revealed[p]) this.#revealed[p] = true; // mutate in place
    }
  }

  /** Finish onboarding — everything shows normally from here. */
  done(): void {
    this.active = false;
  }

  /** Should `part` be visible? Always yes when onboarding is inactive. */
  shows(part: Part): boolean {
    return !this.active || this.#revealed[part];
  }
}

export const onboarding = new Onboarding();
