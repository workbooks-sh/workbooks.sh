// Onboarding reveal state (wb-aakl.20). Shared so the REAL shell pieces
// (Titlebar, Sidebar, main content, the agent badge) can reveal themselves
// one at a time as the coach advances — onboarding is a tutorial of the
// actual UI, not a mock. When inactive (normal app), everything shows.

type Part = "titlebar" | "sidebar" | "canvas" | "agent";

class Onboarding {
  active = $state(false);
  #revealed = $state<Record<Part, boolean>>({
    titlebar: false,
    sidebar: false,
    canvas: false,
    agent: false,
  });

  start(): void {
    this.active = true;
  }

  reveal(...parts: Part[]): void {
    const next = { ...this.#revealed };
    for (const p of parts) next[p] = true;
    this.#revealed = next;
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
