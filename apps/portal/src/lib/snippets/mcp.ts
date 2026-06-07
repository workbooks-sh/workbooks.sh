import type { Verb } from "@brandnana/schema/verbs";

/** MCP config snippet + tool-call hint. Static config is the same for every verb. */
export function mcpSnippet(verb: Verb): string {
  const toolName = verb.id.replace(/\./g, "_");

  const config = JSON.stringify(
    {
      mcpServers: {
        brandnana: {
          command: "brandnana",
          args: ["mcp"],
        },
      },
    },
    null,
    2,
  );

  return `// Add to your MCP client config (e.g. ~/.claude/settings.json):
${config}

// Then call the tool:
// Tool name: ${toolName}`;
}
