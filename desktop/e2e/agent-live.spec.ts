import { test, expect } from "@playwright/test";

// LIVE end-to-end agent evals — the desktop UI driving the REAL agent over the real
// runtime socket (NOT the mock). This is the "end to end in the desktop app" proof:
// a prompt goes to /api/agent/run, the agent (Minimax M3) streams back, and the
// desktop renders what it emits.
//
// Gated behind WB_LIVE_E2E=1 because it needs a live runtime + an LLM key (real
// network, non-deterministic, ~10-30s/case). Setup:
//
//   # 1. boot a runtime with the product model + a key
//   cd runtime && WB_LLM_MODEL=minimax/minimax-m3 OPENROUTER_API_KEY=… mix run --no-halt &
//   # 2. point the desktop frontend at it (flips the mock off — sidecar.svelte.ts)
//   cd desktop && VITE_WB_RUNTIME_URL=http://127.0.0.1:4000 bun run dev
//   # 3. run these
//   WB_LIVE_E2E=1 WB_E2E_PORT=5178 bunx playwright test agent-live.spec.ts
//
// Mirrors the headless capability suite (runtime/bench/agent_capabilities.exs) at the
// UI layer: component-render and workbook-create are the reliable paths; workbook-edit
// is a known red (wb-0lw8 — the agent loop cuts narrate-then-act models off before the
// write), so it's documented, not asserted green.

const COMPOSER = "What would you like to do?";
const live = process.env.WB_LIVE_E2E === "1";

test.describe(live ? "agent live (desktop ↔ real runtime)" : "agent live (skipped — set WB_LIVE_E2E=1)", () => {
  test.skip(!live, "needs a live runtime + LLM key (WB_LIVE_E2E=1)");
  // The real LLM round-trip is slow; give each case room.
  test.setTimeout(90_000);

  async function send(page: import("@playwright/test").Page, prompt: string) {
    const composer = page.getByPlaceholder(COMPOSER);
    await expect(composer).toBeVisible();
    await composer.fill(prompt);
    await composer.press("ControlOrMeta+Enter");
  }

  test("renders an inline component the agent emits (work-gen-block)", async ({ page }) => {
    await page.goto("/");
    await send(
      page,
      "I just finished wiring up the Apollo project. Confirm it back to me with a small inline " +
        "component (not a markdown table) summarizing: Name = Apollo, Status = Ready.",
    );
    // The real agent streams a #+begin_src component block → messageRender mounts the
    // real SDK element. Assert it upgraded (shadow root + a type attribute), not raw text.
    const block = page.locator("work-gen-block").first();
    await expect(block).toBeVisible({ timeout: 60_000 });
    const upgraded = await block.evaluate(
      (el) => !!(el as HTMLElement & { shadowRoot: ShadowRoot | null }).shadowRoot && el.getAttribute("type") != null,
    );
    expect(upgraded).toBe(true);
  });

  test("creates a workbook end-to-end (agent acts + confirms in the transcript)", async ({ page }) => {
    await page.goto("/");
    await send(
      page,
      "Create a workbook named launch-plan.org with the title 'Launch Plan' and two sections: " +
        "Overview and Timeline. Then open it for me.",
    );
    // What vite CAN prove end-to-end: the prompt reaches the real agent, it acts
    // (vfs_write + `wb app open-tab` — confirmed in the runtime log), and confirms
    // back in the transcript. Assert the agent's reply lands referencing the workbook.
    //
    // NOTE: the open-tab → actual desktop TAB requires the native Tauri shell (the
    // desktop:control channel + tab host). The vite-override harness exercises the
    // agent's tool use, not the native tab surface — assert that in the Tauri build.
    // Scope to the AGENT's rendered reply (.agent-text / .agent-org / work-gen-block) —
    // the user's echoed prompt has none of these classes, so it can't false-pass.
    const reply = page.locator(".agent-text, .agent-org, work-gen-block");
    await expect(reply.filter({ hasText: /launch.?plan|created|workbook|overview|done/i }).first()).toBeVisible({
      timeout: 60_000,
    });
  });
});
