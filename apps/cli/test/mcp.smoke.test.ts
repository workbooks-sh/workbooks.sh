// Smoke test: spawn `brandnana mcp` as a subprocess, send a tools/list
// MCP request over stdin, and verify ≥10 expected tool names appear in
// the response.
//
// Run with: bun test apps/cli/test/mcp.smoke.test.ts

import { describe, expect, it } from "bun:test";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CLI_ENTRY = join(__dirname, "../src/index.ts");

// Expected tool names that must appear in the tool list (a representative
// sample across auth, brand, ads, social, usage categories).
const EXPECTED_TOOLS = [
  "auth_login",
  "auth_whoami",
  "auth_status",
  "brand_fetch",
  "brand_fonts",
  "brand_styleguide",
  "ads_search",
  "catalog_crawl",
  "brief_get",
  "design_tokens",
  "resolve_query",
  "social_instagram_profile",
  "social_tiktok_profile",
  "social_youtube_channel",
  "social_twitter_profile",
  "usage_get",
  "system_health",
];

// MCP JSON-RPC tools/list request
const TOOLS_LIST_REQUEST = JSON.stringify({
  jsonrpc: "2.0",
  id: 1,
  method: "tools/list",
  params: {},
});

// MCP initialize request (required by the protocol before tools/list)
const INITIALIZE_REQUEST = JSON.stringify({
  jsonrpc: "2.0",
  id: 0,
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "smoke-test", version: "0.0.0" },
  },
});

function mcpToolsList(timeoutMs = 10_000): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [CLI_ENTRY, "mcp"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        // Provide a dummy key so the server starts without a keychain prompt.
        BRANDNANA_API_KEY: "smoke-test-dummy-key",
      },
    });

    let stdout = "";
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`MCP server timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    proc.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      // Try to parse complete JSON-RPC lines as they arrive
      const lines = stdout.split("\n");
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const msg = JSON.parse(trimmed) as { id?: number; result?: { tools?: { name: string }[] } };
          if (msg.id === 1 && msg.result?.tools) {
            clearTimeout(timer);
            proc.kill();
            resolve(msg.result.tools.map((t) => t.name));
            return;
          }
        } catch {
          // Not yet a complete JSON object — wait for more data
        }
      }
    });

    proc.stderr.on("data", () => {
      // Swallow stderr
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });

    proc.on("close", (code) => {
      clearTimeout(timer);
      if (stdout.includes('"tools"')) {
        // Already resolved above; this is the post-kill close event
        return;
      }
      reject(new Error(`MCP server exited early with code ${code ?? "?"}`));
    });

    // Send the MCP handshake: initialize, then tools/list
    proc.stdin.write(INITIALIZE_REQUEST + "\n");
    proc.stdin.write(TOOLS_LIST_REQUEST + "\n");
  });
}

describe("brandnana mcp smoke — tools/list via subprocess", () => {
  it("returns ≥10 tools and includes every expected tool name", async () => {
    const toolNames = await mcpToolsList();

    expect(toolNames.length).toBeGreaterThanOrEqual(10);

    for (const expected of EXPECTED_TOOLS) {
      expect(toolNames).toContain(expected);
    }
  }, 15_000);
});
