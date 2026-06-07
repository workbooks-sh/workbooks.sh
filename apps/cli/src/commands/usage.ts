import { VERBS } from "@brandnana/schema";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, runAction } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

export function registerUsage(program: Command) {
  program
    .command("usage")
    .description(verbSummary("usage.get"))
    .option("--since-hours <n>", "Window length in hours (1-2160)", "24")
    .option("--base-url <url>", "Override API base URL")
    .action((opts: { sinceHours: string; baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        const report = await client.usage.get(Number.parseInt(opts.sinceHours, 10));

        const lines = [
          `Usage for the past ${report.since_hours}h (tenant ${report.tenant})`,
          "",
          `API key  ${report.api_key.id}`,
          `         ${report.api_key.current_window_count}/${report.api_key.rate_limit_per_min} requests in the current minute`,
          "",
          "Provider                  Calls   Hit%   Cost",
        ];
        for (const p of report.providers) {
          const hitPct = p.calls > 0 ? Math.round((p.cache_hits / p.calls) * 100) : 0;
          lines.push(
            `${p.provider.padEnd(24)} ${String(p.calls).padStart(6)}  ${String(hitPct).padStart(3)}%  $${p.estimated_cost_usd.toFixed(2)}`,
          );
        }
        lines.push(
          "",
          `Totals: ${report.totals.calls} calls, ${report.totals.cache_hit_rate}% cache hit rate, $${report.totals.estimated_cost_usd.toFixed(2)} estimated cost`,
        );

        emit(report, lines.join("\n"));
      }),
    );
}
