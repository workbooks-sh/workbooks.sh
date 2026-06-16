import { test, expect } from "@playwright/test";

// Coverage for the two flows shipped this session: New folder (#1) and chat-as-tab (#5).

test("right-click empty library space opens a New folder action → modal", async ({ page }) => {
  await page.goto("/");
  // The create menu opens via right-click on EMPTY sidebar space (it bails on buttons),
  // so click low in the nav where there are no library items.
  const nav = page.locator('nav[aria-label="Primary"]');
  await expect(nav).toBeVisible();
  const box = await nav.boundingBox();
  await nav.click({ button: "right", position: { x: 20, y: (box?.height ?? 600) - 30 } });
  const newFolder = page.getByRole("button", { name: /^New folder$/ });
  await expect(newFolder).toBeVisible();
  await newFolder.click();
  await expect(page.getByRole("dialog", { name: /new folder/i })).toBeVisible();
});

test("composer send opens a chat tab (chat-as-tab)", async ({ page }) => {
  await page.goto("/");
  const composer = page.getByPlaceholder("What would you like to do?");
  await expect(composer).toBeVisible();
  await composer.fill("hello agent");
  // The composer submits on ⌘/Ctrl+Enter (plain Enter is a newline).
  await composer.press("ControlOrMeta+Enter");
  // The first send opens a returnable chat tab instead of an in-place page thread.
  await expect(page.getByRole("tab").filter({ hasText: /waldo|chat/i })).toBeVisible({
    timeout: 12_000,
  });
});
