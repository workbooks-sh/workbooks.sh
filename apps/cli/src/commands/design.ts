import { VERBS } from "@brandnana/schema";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, runAction } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

/**
 * `brandnana design <subcommand>` — brand design intelligence.
 *
 * v1 surface:
 *   - `tokens <domain>` — fetch a normalised design-tokens.json for a brand
 *
 * Planned (wb-5w9s.7 epic):
 *   - `extract-frames <ad-id>` — VLM image→HTML on key ad frames
 *   - `extract-css <domain>` — Browser Rendering-backed computed-style scrape
 *   - `synthesize <domain>` — combine the above into design.md + motion.md
 */
export function registerDesign(program: Command) {
  const design = program.command("design").description("Brand design intelligence");

  design
    .command("tokens <domain>")
    .description(verbSummary("design.tokens"))
    .option("--base-url <url>", "Override API base URL")
    .action((domain: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        const tokens = await client.design.tokens(domain);
        emit(tokens, formatTokensForHuman(tokens));
      }),
    );
}

function formatTokensForHuman(t: {
  domain: string;
  palette: { primary: string | null; secondary: string | null; accent: string | null; neutrals: string[]; all: string[] };
  fonts: Array<{ family: string; dominance: number | null; uses: string[] }>;
  voice: { name: string | null; slogan: string | null; description: string | null };
}): string {
  const lines: string[] = [];
  lines.push(`design tokens: ${t.domain}`);
  if (t.voice.name) lines.push(`  brand: ${t.voice.name}`);
  if (t.voice.slogan) lines.push(`  slogan: "${t.voice.slogan}"`);
  lines.push("");
  lines.push("  palette:");
  lines.push(`    primary:   ${t.palette.primary ?? "—"}`);
  lines.push(`    secondary: ${t.palette.secondary ?? "—"}`);
  lines.push(`    accent:    ${t.palette.accent ?? "—"}`);
  if (t.palette.neutrals.length > 0) {
    lines.push(`    neutrals:  ${t.palette.neutrals.join(", ")}`);
  }
  lines.push("");
  if (t.fonts.length > 0) {
    lines.push("  fonts:");
    for (const f of t.fonts.slice(0, 5)) {
      const dom = f.dominance != null ? `  (${(f.dominance * 100).toFixed(1)}%)` : "";
      lines.push(`    ${f.family}${dom}`);
    }
    if (t.fonts.length > 5) lines.push(`    … and ${t.fonts.length - 5} more`);
  }
  return lines.join("\n");
}
