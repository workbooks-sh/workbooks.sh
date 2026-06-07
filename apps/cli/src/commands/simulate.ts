// brandnana simulate <verb> [--payload <json>] [--rate-card-id <id>] [--tag <tag>]
//
// If BRANDNANA_ADMIN_KEY is set (or ~/.config/brandnana/admin-key exists),
// hits admin.brandnana.net/simulate (full power).
//
// Otherwise falls through to a "not yet implemented" stub — a follow-up
// bd issue will add the public simulate endpoint at api.brandnana.net/v1/simulate.

import type { Command } from "commander";
import { getAdminKey, makeAdminClient, type SimulateResponse } from "../admin-client.js";
import { emit, emitError, runAction } from "../output.js";

// ── Formatting helpers ────────────────────────────────────────────────────────

function usd(n: number): string {
  return `$${n.toFixed(4)}`;
}

// Right-align a string within a given width.
function rpad(s: string, w: number): string {
  return s.padStart(w);
}

function formatSimulate(verbId: string, res: SimulateResponse): string {
  const lines: string[] = [];

  const col1 = 16; // label width
  const col2 = 12; // value width

  // Normalise field names: live API uses projected_* prefix
  const vendorCost = res.vendor_cost_usd ?? res.projected_vendor_cost_usd ?? 0;
  const customerCharge = res.customer_charge_usd ?? res.projected_customer_charge_usd ?? 0;
  const margin = res.margin_usd ?? res.projected_margin_usd ?? 0;

  lines.push(`${"verb".padEnd(col1)}: ${res.verb_id ?? verbId}`);
  lines.push(`${"vendor cost".padEnd(col1)}: ${rpad(usd(vendorCost), col2)}`);

  const markupLabel = res.markup_label ? `  (${res.markup_label})` : "";
  lines.push(
    `${"customer".padEnd(col1)}: ${rpad(usd(customerCharge), col2)}${markupLabel}`,
  );
  lines.push(`${"margin".padEnd(col1)}: ${rpad(usd(margin), col2)}`);

  if (res.breakdown && res.breakdown.length > 0) {
    lines.push(`${"breakdown".padEnd(col1)}:`);
    for (const item of res.breakdown) {
      // API returns either {provider, operation, quantity, unit_cost_usd, subtotal_usd}
      // or {provider, model, unit, estimated_units, price_usd_per_unit, total_usd}
      const providerLabel = item.provider ?? "";
      const opLabel = item.model ? `${item.model} (${item.unit ?? item.operation ?? ""})` : (item.operation ?? item.unit ?? "");
      const qty = item.quantity ?? item.estimated_units ?? 0;
      const unitCost = item.unit_cost_usd ?? item.price_usd_per_unit ?? 0;
      const total = item.subtotal_usd ?? item.total_usd ?? 0;
      const label = `  ${providerLabel.padEnd(12)} ${opLabel.slice(0, 28).padEnd(28)}`;
      const qtyStr = `${qty} × $${unitCost.toFixed(6)}`;
      const totalStr = `= $${total.toFixed(6)}`;
      lines.push(`${label} ${qtyStr.padEnd(24)} ${totalStr}`);
    }
  }

  if (res.note) {
    lines.push(`${"note".padEnd(col1)}: ${res.note}`);
  }

  return lines.join("\n");
}

// ── Register ──────────────────────────────────────────────────────────────────

export function registerSimulate(program: Command): void {
  program
    .command("simulate <verb>")
    .description("Simulate the cost of a verb call without invoking it")
    .option("--payload <json>", "JSON payload to pass to the simulator")
    .option("--rate-card-id <id>", "Customer rate card ID to use")
    .option("--tag <tag>", "Customer rate card tag to use")
    .action(
      (
        verb: string,
        opts: { payload?: string; rateCardId?: string; tag?: string },
      ) =>
        runAction(async () => {
          const adminKey = getAdminKey();

          if (!adminKey) {
            // No admin key — public simulate endpoint not yet live.
            // Filed as follow-up bd issue: add GET /v1/simulate to api.brandnana.net.
            process.stderr.write(
              "brandnana simulate: public simulate endpoint not yet available.\n" +
                "Set BRANDNANA_ADMIN_KEY (or write ~/.config/brandnana/admin-key) to use admin.brandnana.net/simulate.\n",
            );
            process.exit(1);
          }

          const client = makeAdminClient();

          let payload: unknown = undefined;
          if (opts.payload) {
            try {
              payload = JSON.parse(opts.payload);
            } catch {
              throw new Error(`--payload is not valid JSON: ${opts.payload}`);
            }
          }

          const res = await client.simulate({
            verb_id: verb,
            payload,
            customer_rate_card_id: opts.rateCardId,
            customer_rate_card_tag: opts.tag,
          });

          emit(res, formatSimulate(verb, res));
        }),
    );
}
