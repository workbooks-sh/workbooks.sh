import { test, expect } from "@playwright/test";

// E2E against the vite-served frontend with mock providers. Default route = the
// signed-in, onboarding-done "ready app".

test.describe("ready app", () => {
  test("boots signed-in — no sign-in gate, titlebar + sidebar present", async ({ page }) => {
    await page.goto("/");
    // The grand sign-in gate's CTA must NOT be present when signed-in.
    await expect(page.getByRole("button", { name: /get started/i })).toHaveCount(0);
    // The org/nexus chip lives in the titlebar for every layout.
    await expect(page.getByRole("button", { name: /switch nexus/i })).toBeVisible();
  });

  test("nexus chip opens a popover with Personal (local)", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("button", { name: /switch nexus/i }).click();
    // Scope to the nexus dialog (a workspace can also be named "Personal").
    const popover = page.getByRole("dialog", { name: "Nexus" });
    await expect(popover).toBeVisible();
    await expect(popover.getByText("Personal")).toBeVisible();
    await expect(popover.getByText("local")).toBeVisible();
  });

  test("workspace switcher row has an ⋯ actions menu (Edit / Leave)", async ({ page }) => {
    await page.goto("/");
    // Open the workspace switcher (sidebar top).
    await page.getByRole("button", { name: /switch workspace/i }).click();
    const wsDialog = page.getByRole("dialog", { name: /workspace/i });
    await expect(wsDialog).toBeVisible();
    // Hover a row to reveal its ⋯, open the actions menu.
    await wsDialog.getByRole("button", { name: "Workspace actions" }).first().click();
    await expect(page.getByRole("button", { name: /^Edit$/ })).toBeVisible();
    await expect(page.getByRole("button", { name: /^Leave$/ })).toBeVisible();
  });
});

test.describe("onboarding", () => {
  test("?onboarding=fresh leaves the ready app (gate or tour)", async ({ page }) => {
    await page.goto("/?onboarding=fresh");
    // In the fresh state the app is NOT immediately interactive as the ready shell:
    // either the sign-in gate or the coach is up. Assert the gate CTA is reachable.
    await expect(page.getByRole("button", { name: /get started/i })).toBeVisible({ timeout: 12_000 });
  });
});
