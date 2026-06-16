import { test, expect } from "@playwright/test";

// E2E for the COMPONENT MODEL dogfood path: the chat composer emits an inline
// `#+begin_src component …` block, which the message renderer forwards to the
// REAL <work-gen-block> SDK element (workponents `ai` domain) via
// WorkGenBlock.svelte — one implementation, themed through the --work-* bridge.
// This is the "chat emits a workponent" loop the composition model centers on.
//
// Runs against the vite-served frontend with the webHost mock providers (default
// route = signed-in, runtime "ready", an OpenRouter key present). On that route
// the home composer sends through chatSession.send → the scripted mock agent
// (runMockComponentAgent), so no real runtime/LLM is needed. A "create …" prompt
// drives the `create` intent, which streams two component blocks (a callout + a
// kv card) → two <work-gen-block> elements render in the transcript.

const COMPOSER = "What would you like to do?";
// A prompt the mock agent's intent detector routes to `create` (emits the
// component blocks). Keep it phrased so detectIntent() matches workbook|app|….
const CREATE_PROMPT = "create a workbook for me";

test.describe("composition · chat emits a work-* component", () => {
  test("a create prompt renders a <work-gen-block> in the transcript", async ({ page }) => {
    await page.goto("/");

    // The composer is the home surface; it sends once the runtime is ready and a
    // model key exists (both supplied by the mock). Type, then submit.
    const composer = page.getByPlaceholder(COMPOSER);
    await expect(composer).toBeVisible();
    await composer.fill(CREATE_PROMPT);

    // ⌘↵ / Ctrl↵ submits (the composer's keyboard send path).
    await composer.press("ControlOrMeta+Enter");

    // The user echo lands immediately; the scripted agent then streams the
    // component block. Assert the REAL custom element upgraded + rendered chrome.
    const genBlock = page.locator("work-gen-block").first();
    await expect(genBlock).toBeVisible({ timeout: 15_000 });

    // Prove it is the upgraded SDK element (a shadow root + the forwarded `type`
    // attribute), not an unrendered tag — i.e. the dogfood wiring actually mounted
    // the workponent, themed via the bridge.
    const upgraded = await genBlock.evaluate(
      (el) => !!el.shadowRoot && el.getAttribute("type") != null,
    );
    expect(upgraded).toBe(true);
  });

  test("the emitted component carries the agent-authored props (type=callout)", async ({ page }) => {
    await page.goto("/");

    const composer = page.getByPlaceholder(COMPOSER);
    await expect(composer).toBeVisible();
    await composer.fill(CREATE_PROMPT);
    await composer.press("ControlOrMeta+Enter");

    // The `create` branch authors a `:type callout` block first — the renderer
    // forwards `type` (and the parsed header args) as ATTRIBUTES, never {@html}.
    const callout = page.locator('work-gen-block[type="callout"]').first();
    await expect(callout).toBeVisible({ timeout: 15_000 });
  });
});
