import { defineConfig, devices } from "@playwright/test";

// E2E against the REAL frontend served by vite, with the webHost mock providers
// (window.__WB_DEV_MOCK__ = true in app.html). The native Tauri shell isn't driven
// here — these cover the UI flows that run in the webview. Deterministic states:
//   • default            → signed-in, onboarding done (the ready app)
//   • ?onboarding=fresh   → signed-out + first-run (the sign-in gate / tour)
//
// Port: defaults to vite's committed 5178; override with WB_E2E_PORT (e.g. 5180 when
// a dev server is already running on the worktree's shifted port).
const PORT = process.env.WB_E2E_PORT || "5178";
const BASE = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: "e2e",
  timeout: 30_000,
  expect: { timeout: 8_000 },
  fullyParallel: true,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"]],
  use: {
    baseURL: BASE,
    headless: true,
    trace: "on-first-retry",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    command: "bun run dev",
    url: BASE,
    reuseExistingServer: true,
    timeout: 90_000,
  },
});
