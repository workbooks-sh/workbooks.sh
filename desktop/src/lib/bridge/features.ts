/**
 * Feature flags (wb-aakl.1) — the seam that turns the full desktop app
 * into the shipped "workbooks browser".
 *
 * Each flag is read from a Vite build-time env var (WB_FF_* — exposed via
 * `envPrefix` in vite.config). ALL DEFAULT FALSE: a release build excludes
 * agents, auth UI, network/social, integrations, and the old setup
 * onboarding gates unless the operator explicitly turns one on at build:
 *
 *   WB_FF_AGENTS=true bun run build
 *
 * Build-time EXCLUSION, not just hiding: because each value resolves to a
 * literal `import.meta.env.WB_FF_*` read, Vite substitutes it at build and
 * an `{#if features.X}` guarding a lazily `import()`ed component lets the
 * dead branch — and its split chunk — drop out of the bundle entirely. In
 * the dev server every flag is whatever the shell env says (default off),
 * with `?ff=agents,network` as a transient override for previewing a
 * flagged surface without a rebuild.
 *
 * This file touches NO Tauri commands — flags gate consuming UI only; the
 * invoke seam / webHost stays stable regardless of what's flagged off.
 */

const truthy = (v: unknown): boolean => v === "true" || v === "1" || v === true;

const env = import.meta.env as Record<string, unknown>;

// Dev-only URL override: ?ff=agents,network turns those on for this load.
// Stripped from production reasoning — import.meta.env.DEV is a build
// constant, so the whole block DCEs out of a release build.
function urlOverrides(): Set<string> {
  if (!import.meta.env.DEV || typeof window === "undefined") return new Set();
  const raw = new URLSearchParams(window.location.search).get("ff");
  return new Set(
    (raw ?? "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
  );
}

const overrides = urlOverrides();
const flag = (key: string, envVal: unknown): boolean =>
  truthy(envVal) || overrides.has(key);

export const features = {
  /** Multi-agent chat chrome (chat/). The resident agent "Waldo" is a
   *  separate keeper surface (wb-aakl.21), not gated by this. */
  agents: flag("agents", env.WB_FF_AGENTS),
  /** WorkOS sign-in overlay + account card. Sidecar gate is NOT this. */
  authUI: flag("auth", env.WB_FF_AUTH_UI),
  /** Network/social layer (network/) + its rail tab. */
  network: flag("network", env.WB_FF_NETWORK),
  /** Integrations + Skills + MCPs + Plugins settings tabs. */
  integrations: flag("integrations", env.WB_FF_INTEGRATIONS),
  /** Old runtime/key/keychain setup gates (setup/). The personalization
   *  onboarding (wb-aakl.20) is a keeper and is NOT gated by this. */
  onboarding: flag("onboarding", env.WB_FF_ONBOARDING),
} as const;

export type FeatureName = keyof typeof features;
