// MCP stdio server — every brandnana verb exposed as an MCP tool.
//
// Usage:
//   brandnana mcp               — start the MCP stdio server
//   brandnana mcp --list-tools  — print tool list as JSON, then exit
//   brandnana mcp --debug       — stream stderr logs while running
//
// Connect from Claude Desktop / Claude Code / Cursor by adding to your
// MCP config:
//   {
//     "mcpServers": {
//       "brandnana": {
//         "command": "brandnana",
//         "args": ["mcp"]
//       }
//     }
//   }

import type { Command } from "commander";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { VERBS, type Verb, type VerbInput } from "@brandnana/schema/verbs";
import { getApiKey } from "../keychain.js";
import { baseUrlFromEnv } from "../client.js";

// ── Type mapping ─────────────────────────────────────────────────────────────

function inputToJsonSchema(input: VerbInput): Record<string, unknown> {
  switch (input.type) {
    case "string":
      return { type: "string", description: input.description };
    case "number":
      return { type: "number", description: input.description };
    case "boolean":
      return { type: "boolean", description: input.description };
    case "string[]":
      return { type: "array", items: { type: "string" }, description: input.description };
    default:
      // Union types like "'exa'|'meta'|..." — represent as string, annotate type
      return { type: "string", description: `${input.description} (type: ${input.type})` };
  }
}

function verbToInputSchema(verb: Verb): {
  type: "object";
  properties: Record<string, unknown>;
  required: string[];
} {
  const properties: Record<string, unknown> = {};
  const required: string[] = [];
  for (const input of verb.inputs) {
    properties[input.name] = inputToJsonSchema(input);
    if (input.required) required.push(input.name);
  }
  return { type: "object", properties, required };
}

// ── Tool name ────────────────────────────────────────────────────────────────

function verbId(verb: Verb): string {
  return verb.id.replace(/\./g, "_");
}

// ── HTTP path expansion ───────────────────────────────────────────────────────
// Replace :param with the corresponding input value.

function expandPath(httpPath: string, params: Record<string, unknown>): string {
  return httpPath.replace(/:([a-zA-Z_][a-zA-Z0-9_]*)/g, (_, name: string) => {
    const v = params[name];
    return v != null ? encodeURIComponent(String(v)) : `:${name}`;
  });
}

// ── Build the tool list ───────────────────────────────────────────────────────

function buildToolList() {
  return VERBS.map((verb) => ({
    name: verbId(verb),
    description: verb.summary,
    inputSchema: verbToInputSchema(verb),
  }));
}

// ── Call handler ─────────────────────────────────────────────────────────────

async function callVerb(
  verb: Verb,
  args: Record<string, unknown>,
  apiKey: string,
  baseUrl: string,
  debug: boolean,
): Promise<{ content: Array<{ type: "text"; text: string }>; isError?: boolean }> {
  // Determine URL — skip verbs with no httpPath (audit.trace is local-only)
  if (!verb.httpPath) {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            error: `Verb ${verb.id} is a local CLI-only operation not available via the API.`,
          }),
        },
      ],
      isError: true,
    };
  }

  // Build path params — anything referenced as :param in httpPath
  const pathParamNames = (verb.httpPath.match(/:([a-zA-Z_][a-zA-Z0-9_]*)/g) ?? []).map((p) =>
    p.slice(1),
  );
  const pathParams: Record<string, unknown> = {};
  for (const name of pathParamNames) {
    if (args[name] != null) pathParams[name] = args[name];
  }

  const expandedPath = expandPath(verb.httpPath, pathParams);
  const url = `${baseUrl}${expandedPath}`;

  if (debug) {
    process.stderr.write(`[brandnana-mcp] ${verb.httpMethod} ${url}\n`);
  }

  // Remaining args (not path params) become query string or body
  const remainingArgs: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args)) {
    if (!pathParamNames.includes(k) && v != null) remainingArgs[k] = v;
  }

  let fetchUrl = url;
  let fetchInit: RequestInit = {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
  };

  if (verb.httpMethod === "GET") {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(remainingArgs)) {
      if (Array.isArray(v)) {
        for (const item of v) qs.append(k, String(item));
      } else {
        qs.set(k, String(v));
      }
    }
    const qsStr = qs.toString();
    if (qsStr) fetchUrl = `${url}${url.includes("?") ? "&" : "?"}${qsStr}`;
    fetchInit = { ...fetchInit, method: "GET" };
  } else {
    fetchInit = {
      ...fetchInit,
      method: verb.httpMethod,
      body: JSON.stringify(remainingArgs),
    };
  }

  let resp: Response;
  try {
    resp = await fetch(fetchUrl, fetchInit);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      content: [{ type: "text", text: JSON.stringify({ error: `Network error: ${msg}` }) }],
      isError: true,
    };
  }

  const text = await resp.text();
  if (!resp.ok) {
    if (debug) {
      process.stderr.write(`[brandnana-mcp] ${resp.status} ${text.slice(0, 200)}\n`);
    }
    return {
      content: [{ type: "text", text }],
      isError: true,
    };
  }

  return { content: [{ type: "text", text }] };
}

// ── Register the subcommand ───────────────────────────────────────────────────

export function registerMcp(program: Command): void {
  program
    .command("mcp")
    .description("Start an MCP stdio server exposing every brandnana verb as an MCP tool")
    .option("--list-tools", "Print the tool list as JSON, then exit")
    .option("--debug", "Stream verbose logs to stderr")
    .action(async (opts: { listTools?: boolean; debug?: boolean }) => {
      const debug = opts.debug ?? false;

      // --list-tools: print and exit without starting the server
      if (opts.listTools) {
        process.stdout.write(JSON.stringify(buildToolList(), null, 2));
        process.stdout.write("\n");
        process.exit(0);
      }

      // Resolve auth upfront to give a fast, clear error
      const apiKey = process.env["BRANDNANA_API_KEY"] ?? (await getApiKey());
      const baseUrl = baseUrlFromEnv();

      const server = new Server(
        { name: "brandnana", version: "0.0.0" },
        { capabilities: { tools: {} } },
      );

      // tools/list
      server.setRequestHandler(ListToolsRequestSchema, async () => {
        return { tools: buildToolList() };
      });

      // tools/call
      server.setRequestHandler(CallToolRequestSchema, async (request) => {
        const { name, arguments: rawArgs } = request.params;
        const args = (rawArgs ?? {}) as Record<string, unknown>;

        if (debug) {
          process.stderr.write(`[brandnana-mcp] tool call: ${name}\n`);
        }

        // No token — return actionable error
        if (!apiKey) {
          return {
            content: [
              {
                type: "text" as const,
                text: "No brandnana API key found. Run `brandnana auth login` first.",
              },
            ],
            isError: true,
          };
        }

        // Look up the verb by its tool name (dots-to-underscores ID)
        const verb = VERBS.find((v) => verbId(v) === name);
        if (!verb) {
          return {
            content: [{ type: "text" as const, text: `Unknown tool: ${name}` }],
            isError: true,
          };
        }

        return await callVerb(verb, args, apiKey, baseUrl, debug);
      });

      const transport = new StdioServerTransport();

      if (debug) {
        process.stderr.write(`[brandnana-mcp] starting server with ${VERBS.length} tools\n`);
      }

      await server.connect(transport);
    });
}
