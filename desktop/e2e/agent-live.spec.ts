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

  test("renders an inline component the agent emits — VISUALLY, not just mounted", async ({ page }) => {
    await page.goto("/");
    await send(
      page,
      "I just finished wiring up the Apollo project. Confirm it back to me with a small inline " +
        "component (not a markdown table) summarizing: Name = Apollo, Status = Ready.",
    );
    const block = page.locator("work-gen-block").first();
    await expect(block).toBeVisible({ timeout: 60_000 });

    // Deep render validation — the full chain emit → parse → mount → RENDER, not just
    // "the tag upgraded". Catches the real UI failures: mounted-but-collapsed (zero box),
    // empty shadow (rendered nothing), unstyled (theme tokens never applied), and
    // data-not-bound (the agent's values never reached the rendered output).
    const r = await block.evaluate((el) => {
      const e = el as HTMLElement & { shadowRoot: ShadowRoot | null };
      const root = e.shadowRoot;
      const box = e.getBoundingClientRect();
      const card = root?.firstElementChild as HTMLElement | null;
      const cs = card ? getComputedStyle(card) : null;
      const text = (root?.textContent || "").replace(/\s+/g, " ").trim();
      return {
        upgraded: !!root && el.getAttribute("type") != null,
        painted: box.width > 4 && box.height > 4,
        childCount: root?.querySelectorAll("*").length ?? 0,
        // the agent's DATA rendered visibly (not lost between emit and paint)
        dataBound: /apollo/i.test(text) && /ready/i.test(text),
        // theme tokens actually applied — a real card has bg OR border OR padding,
        // never a bare unstyled box
        themed:
          !!cs &&
          (cs.backgroundColor !== "rgba(0, 0, 0, 0)" ||
            parseFloat(cs.borderTopWidth) > 0 ||
            parseFloat(cs.paddingTop) > 0),
      };
    });

    // Artifact for eyeballing the actual render.
    await block.screenshot({ path: "test-results/agent-live-component.png" }).catch(() => {});

    expect(r.upgraded, "custom element upgraded").toBe(true);
    expect(r.painted, "component actually painted (non-collapsed box)").toBe(true);
    expect(r.childCount, "shadow DOM rendered real content").toBeGreaterThan(0);
    expect(r.dataBound, "the agent's data (Apollo/Ready) rendered visibly").toBe(true);
    expect(r.themed, "theme tokens applied (bg/border/padding), not unstyled").toBe(true);
  });

  test("creates a workbook end-to-end (agent acts + confirms in the transcript)", async ({ page }) => {
    await page.goto("/");
    await send(
      page,
      "Create a workbook named launch-plan.org with the title 'Launch Plan' and two sections: " +
        "Overview and Timeline. Then open it for me.",
    );
    // What vite CAN prove end-to-end: the prompt reaches the real agent, it acts
    // (vfs_write + `work app open-tab` — confirmed in the runtime log), and confirms
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
