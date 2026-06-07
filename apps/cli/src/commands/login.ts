// `brandnana login` — Clerk-based device-flow sign-in.
//
// Replaces the previous GitHub-only flow with one that uses brandnana's own
// auth surface at app.brandnana.net (which is Clerk-backed).
//
// Flow:
//   1. POST /v1/auth/cli/start → { device_code, user_code, verification_url, interval_s, expires_in_s }
//   2. Print user_code + open verification_url in the user's browser
//   3. Poll /v1/auth/cli/poll?device_code=… until status='approved'
//   4. Store the returned api_key in the OS keychain

import { exec } from "node:child_process";
import { hostname, platform, userInfo } from "node:os";
import { promisify } from "node:util";
import { VERBS } from "@brandnana/schema";
import type { Command } from "commander";
import { baseUrlFromEnv } from "../client.js";
import { setApiKey } from "../keychain.js";

const execAsync = promisify(exec);

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

interface StartResponse {
  device_code: string;
  user_code: string;
  verification_url: string;
  expires_in_s: number;
  interval_s: number;
}

interface PollResponse {
  status: "pending" | "approved" | "denied" | "consumed" | "expired";
  api_key?: string;
  user_code?: string;
}

async function openInBrowser(url: string): Promise<void> {
  const cmd =
    platform() === "darwin"
      ? `open "${url}"`
      : platform() === "win32"
        ? `start "" "${url}"`
        : `xdg-open "${url}"`;
  try {
    await execAsync(cmd);
  } catch {
    // Best-effort — if it fails the user can copy/paste the URL.
  }
}

async function startFlow(baseUrl: string, cliVersion: string): Promise<StartResponse> {
  const res = await fetch(`${baseUrl}/v1/auth/cli/start`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_info: {
        hostname: hostname(),
        platform: platform(),
        user: userInfo().username,
        cli_version: cliVersion,
      },
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`auth/cli/start returned ${res.status}: ${body}`);
  }
  return (await res.json()) as StartResponse;
}

async function pollOnce(baseUrl: string, deviceCode: string): Promise<PollResponse> {
  const res = await fetch(
    `${baseUrl}/v1/auth/cli/poll?device_code=${encodeURIComponent(deviceCode)}`,
  );
  if (!res.ok) throw new Error(`auth/cli/poll returned ${res.status}`);
  return (await res.json()) as PollResponse;
}

async function pollUntilDone(
  baseUrl: string,
  start: StartResponse,
): Promise<string> {
  const deadline = Date.now() + start.expires_in_s * 1000;
  let interval = Math.max(start.interval_s, 2);

  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, interval * 1000));
    const r = await pollOnce(baseUrl, start.device_code);
    if (r.status === "approved" && r.api_key) return r.api_key;
    if (r.status === "denied") throw new Error("authorization was denied");
    if (r.status === "expired") throw new Error("code expired — run `brandnana login` again");
    if (r.status === "consumed") throw new Error("code already used — run `brandnana login` again");
    // pending → keep polling
  }
  throw new Error("device-flow timed out — please run `brandnana login` again");
}

export function registerLogin(program: Command) {
  program
    .command("login")
    .description(verbSummary("auth.login") || "Sign in to brandnana from the CLI")
    .option("--base-url <url>", "Override API base URL")
    .option("--no-open", "Don't auto-open the browser; just print the URL")
    .action(async (opts: { baseUrl?: string; open: boolean }) => {
      const baseUrl = baseUrlFromEnv(opts.baseUrl);

      // Best-effort CLI version from package.json (synchronous import).
      const cliVersion =
        (await import("node:fs"))
          .readFileSync(new URL("../../package.json", import.meta.url), "utf8")
          .match(/"version"\s*:\s*"([^"]+)"/)?.[1] ?? "0.0.0";

      const start = await startFlow(baseUrl, cliVersion);

      process.stdout.write(
        [
          "",
          `  → opening ${start.verification_url}`,
          "",
          `  if your browser doesn't open, visit this URL:`,
          `    ${start.verification_url}`,
          "",
          `  confirm this code in the browser:  ${start.user_code}`,
          "",
          "  waiting for approval…",
          "",
        ].join("\n"),
      );

      if (opts.open !== false) {
        await openInBrowser(start.verification_url);
      }

      const apiKey = await pollUntilDone(baseUrl, start);
      const stored = await setApiKey(apiKey);

      process.stdout.write(
        [
          "",
          `  ✓ signed in — key stored in ${stored.storage}`,
          "",
        ].join("\n"),
      );
    });

  program
    .command("logout")
    .description("Remove the stored API key")
    .action(async () => {
      const { deleteApiKey, fallbackLocation } = await import("../keychain.js");
      const ok = await deleteApiKey();
      process.stdout.write(
        ok ? "✓ logged out\n" : `no key found (fallback path was ${fallbackLocation()})\n`,
      );
    });

  program
    .command("whoami")
    .description(verbSummary("auth.whoami") || "Print the signed-in account")
    .option("--base-url <url>", "Override API base URL")
    .action(async (opts: { baseUrl?: string }) => {
      const { clientFromEnv } = await import("../client.js");
      const client = await clientFromEnv(opts.baseUrl);
      const result = await client.call<{
        user: { id: string; github_login: string | null; email: string | null };
      }>("/whoami");
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    });
}
