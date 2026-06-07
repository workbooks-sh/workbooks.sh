// `brandnana brief <domain>` — thin wrapper over GET /brief/:domain.
// Server does the 9-way fan-out; we just render.

import { VERBS } from "@brandnana/schema";
import type { BriefResult } from "@brandnana/sdk";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, runAction, warn } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

interface BriefOptions {
  handle?: string;
  baseUrl?: string;
}

function line(label: string, value: string | null | undefined): string {
  return `${label.padEnd(13)}: ${value ?? "—"}`;
}

function fmt(result: BriefResult): string {
  const b = result.brand?.brand;
  const ig = result.social.instagram as { username?: string; followers?: number } | null;
  const tt = result.social.tiktok as { username?: string; followers?: number } | null;
  const yt = result.social.youtube as { title?: string; subscribers?: number } | null;
  const tw = result.social.twitter as { screen_name?: string; followers?: number } | null;
  const fb = result.social.facebook as { name?: string; page_id?: string } | null;
  const lt = result.social.linktree as { username?: string; link_count?: number } | null;
  const src = result.resolved_handles_source;
  // Mark domain-guessed handles with a "?" so the human reader knows the
  // profile might be an imposter (e.g. @allbirds on TT = 2-follower account
  // when the real one is @weareallbirds).
  const tag = (platform: keyof typeof src) => (src[platform] === "domain_guess" ? " ?" : "");
  const lines = [
    `Brand brief: ${result.domain} (handle ${result.handle})`,
    "",
    line("Brand", b ? `${b.name ?? "(no name)"} — ${b.palette_json ?? "(no palette)"}` : null),
    line(
      "Design",
      result.design.mode || result.design.fonts.length > 0
        ? `${result.design.mode ?? "?"} mode · ${result.design.fonts.slice(0, 3).join(", ") || "no fonts"}${result.design.components.length > 0 ? ` · ${result.design.components.length} component types` : ""}`
        : null,
    ),
    line(
      "Instagram",
      ig ? `@${ig.username} — ${ig.followers ?? "?"} followers${tag("instagram")}` : null,
    ),
    line(
      "TikTok",
      tt ? `@${tt.username} — ${tt.followers ?? "?"} followers${tag("tiktok")}` : null,
    ),
    line("YouTube", yt ? `${yt.title} — ${yt.subscribers ?? "?"} subs${tag("youtube")}` : null),
    line(
      "Twitter",
      tw ? `@${tw.screen_name} — ${tw.followers ?? "?"} followers${tag("twitter")}` : null,
    ),
    line("Facebook", fb ? `${fb.name} (page ${fb.page_id})${tag("facebook")}` : null),
    line("Linktree", lt ? `${lt.username} (${lt.link_count ?? 0} links)` : null),
    line(
      "Meta ads",
      result.ads.meta
        ? `${result.ads.meta.count} on this page${result.ads.meta.has_more ? " (more available — paginate with next_cursor)" : ""}`
        : null,
    ),
    line(
      "Google ads",
      result.ads.google?.advertiser_id
        ? `advertiser ${result.ads.google.advertiser_id} (${result.ads.google.creative_count} creatives on transparency page)`
        : null,
    ),
  ];
  if (result.errors.length > 0) {
    lines.push("", `Errors       : ${result.errors.map((e) => e.section).join(", ")}`);
  }
  const guessed = (Object.keys(src) as Array<keyof typeof src>).filter(
    (k) => src[k] === "domain_guess",
  );
  if (guessed.length > 0) {
    lines.push(
      `? handles    : ${guessed.join(", ")} (inferred from domain — profile may be wrong account)`,
    );
  }
  return lines.join("\n");
}

export function registerBrief(program: Command) {
  program
    .command("brief <domain>")
    .description(verbSummary("brief.get"))
    .option("--handle <handle>", "Social handle (defaults to the second-level domain)")
    .option("--base-url <url>", "Override API base URL")
    .action((domain: string, opts: BriefOptions) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        const result = await client.brief.get(domain, opts.handle);
        if (result.errors.length > 0) {
          warn(
            `brief had ${result.errors.length} partial failures: ${result.errors.map((e) => e.section).join(", ")}`,
          );
        }
        emit(result, fmt(result));
      }),
    );
}
