import { VERBS } from "@brandnana/schema";
import type { AdSource } from "@brandnana/sdk";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, progress, runAction, say, warn } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

const TERMINAL_STATES = new Set(["connected", "error"]);

async function connect(provider: AdSource, baseUrl: string | undefined): Promise<void> {
  const client = await clientFromEnv(baseUrl);
  const start = await client.auth.start({ provider });

  say("");
  say(`Open this URL in your browser to connect ${provider}:`);
  say(`  ${start.auth_url}`);
  say("");
  say(`Waiting (session ${start.session_id})…`);

  const deadline = start.expires_at ?? Date.now() + 15 * 60 * 1000;
  let lastState = "pending";
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 2000));
    const status = await client.auth.status(provider, start.session_id);
    if (status.state !== lastState) {
      progress(`status: ${status.state}`);
      lastState = status.state;
    }
    if (TERMINAL_STATES.has(status.state)) {
      if (status.state === "connected") {
        emit(
          { provider, state: "connected", session_id: start.session_id },
          `✓ ${provider} connected`,
        );
        return;
      }
      throw new Error(`OAuth failed: ${status.error ?? "unknown error"}`);
    }
  }
  throw new Error("OAuth session expired — re-run `brandnana auth meta`");
}

export function registerAuth(program: Command) {
  const auth = program
    .command("auth")
    .description("Manage ad-library connections (Meta, TikTok, Google)");

  for (const provider of ["meta", "tiktok", "google"] as const) {
    auth
      .command(provider)
      .description(verbSummary(`auth.connect.${provider}`))
      .option("--base-url <url>", "Override API base URL")
      .action((opts: { baseUrl?: string }) => runAction(() => connect(provider, opts.baseUrl)));
  }

  auth
    .command("status")
    .description(verbSummary("auth.status"))
    .option("--base-url <url>", "Override API base URL")
    .action((opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        try {
          const connections = await client.auth.connections();
          if (connections.length === 0) {
            warn("no providers connected — run `brandnana auth meta` etc.");
          }
          emit(connections, JSON.stringify(connections, null, 2));
        } catch (e) {
          // /auth/connections may not exist yet on the server.
          warn(`connections endpoint not available: ${(e as Error).message}`);
          emit([], "[]");
        }
      }),
    );
}
