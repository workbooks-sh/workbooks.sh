import { test, expect } from "@playwright/test";

// Adversarial / negative coverage — the things that must NOT happen, and edge cases.
// Default nexus is Personal (local), so all cloud-gated affordances must be hidden.

async function openNewFolder(page: import("@playwright/test").Page) {
  const nav = page.locator('nav[aria-label="Primary"]');
  await expect(nav).toBeVisible();
  const box = await nav.boundingBox();
  await nav.click({ button: "right", position: { x: 20, y: (box?.height ?? 600) - 30 } });
  await page.getByRole("button", { name: /^New folder$/ }).click();
  return page.getByRole("dialog", { name: /new folder/i });
}

test("New folder hides 'Add people' on a local nexus (cloud-gated share)", async ({ page }) => {
  await page.goto("/");
  const dialog = await openNewFolder(page);
  await expect(dialog).toBeVisible();
  // Personal/local has no peers — the share affordance must be absent.
  await expect(dialog.getByText(/add people/i)).toHaveCount(0);
});

test("New folder: Cancel dismisses without creating", async ({ page }) => {
  await page.goto("/");
  const dialog = await openNewFolder(page);
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: /^cancel$/i }).click();
  await expect(dialog).toHaveCount(0);
});

test("workspace ⋯ menu hides Share on a local nexus", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: /switch workspace/i }).click();
  const ws = page.getByRole("dialog", { name: /workspace/i });
  await ws.getByRole("button", { name: "Workspace actions" }).first().click();
  await expect(page.getByRole("button", { name: /^Edit$/ })).toBeVisible();
  await expect(page.getByRole("button", { name: /^Leave$/ })).toBeVisible();
  // Share is cloud-only → must NOT appear for Personal/local.
  await expect(page.getByRole("button", { name: /^Share$/ })).toHaveCount(0);
});

test("nexus popover marks the active context", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: /switch nexus/i }).click();
  const popover = page.getByRole("dialog", { name: "Nexus" });
  await expect(popover).toBeVisible();
  await expect(popover.getByText(/active/i)).toBeVisible();
});

// The exact bug the user hit: opening the nexus dropdown and choosing Personal
// "calls to sign in again". Personal IS local — switching to it is a sync,
// auth-free context change. It must NEVER bounce to the sign-in gate.
test("selecting the Personal (local) nexus does not prompt sign-in", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: /switch nexus/i }).click();
  const popover = page.getByRole("dialog", { name: "Nexus" });
  await expect(popover).toBeVisible();
  await popover.getByRole("button").filter({ hasText: "Personal" }).first().click();
  // No sign-in gate, ever — local has no peers and no auth.
  await expect(page.getByRole("button", { name: /get started/i })).toHaveCount(0);
  // The app stays the ready shell (nexus chip still in the titlebar).
  await expect(page.getByRole("button", { name: /switch nexus/i })).toBeVisible();
});
