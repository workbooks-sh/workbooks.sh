// brandnana book query — OQL-subset query against a published book's
// wb-source-bundle. Extracted from book.ts to keep that file under the 800-LOC
// cap (wb-syjo / wb-t6zl). Pure org parsing + a small OQL-subset matcher + the
// bundle-extraction I/O.

import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { gunzipSync } from "node:zlib";
import { say } from "../output.js";

export interface OrgHeadline {
  level: number;
  title: string;
  tags: string[];
  props: Record<string, string>;
  body: string;
}

export function parseOrgHeadlines(orgText: string): OrgHeadline[] {
  const lines = orgText.split("\n");
  const headlines: OrgHeadline[] = [];
  let current: OrgHeadline | null = null;
  let inProps = false;

  for (const line of lines) {
    const headlineMatch = line.match(/^(\*+)\s+(.*)/);
    if (headlineMatch) {
      if (current) headlines.push(current);
      const stars = headlineMatch[1]?.length ?? 1;
      const rest = headlineMatch[2] ?? "";
      // Extract tags: :tag1:tag2: at end of line.
      const tagMatch = rest.match(/(.*?)\s+:([\w:]+):\s*$/);
      const title = tagMatch ? tagMatch[1]?.trim() ?? rest : rest.trim();
      const tags = tagMatch ? (tagMatch[2]?.split(":").filter(Boolean) ?? []) : [];
      current = { level: stars, title, tags, props: {}, body: "" };
      inProps = false;
      continue;
    }
    if (current) {
      if (line.trim() === ":PROPERTIES:") { inProps = true; continue; }
      if (line.trim() === ":END:") { inProps = false; continue; }
      if (inProps) {
        const propMatch = line.match(/^\s*:([A-Z_][A-Z0-9_]*):\s+(.*)/);
        if (propMatch) {
          current.props[propMatch[1] ?? ""] = propMatch[2]?.trim() ?? "";
        }
        continue;
      }
      current.body += `${line}\n`;
    }
  }
  if (current) headlines.push(current);
  return headlines;
}

export function applyOqlQuery(headlines: OrgHeadline[], query: string): OrgHeadline[] {
  const underMatch = query.match(/\(under\s+"([^"]+)"\)/i);
  const taggedMatch = query.match(/\(tagged\s+(\w+)\)/i);
  const hasPropMatch = query.match(/\(has\s+property\s+:([A-Z_][A-Z0-9_]*):\)/i);

  return headlines.filter((h) => {
    if (underMatch) {
      // Simple substring match against the title for now.
      const path = underMatch[1] ?? "";
      const segments = path.split("/");
      const lastSeg = segments[segments.length - 1] ?? "";
      if (!h.title.toLowerCase().includes(lastSeg.toLowerCase())) return false;
    }
    if (taggedMatch) {
      const want = taggedMatch[1]?.toLowerCase() ?? "";
      if (!h.tags.some((t) => t.toLowerCase() === want)) return false;
    }
    if (hasPropMatch) {
      const key = hasPropMatch[1] ?? "";
      if (!(key in h.props)) return false;
    }
    return true;
  });
}

/** Run an OQL-subset query against the wb-source-bundle of a published book. */
export async function runBookQuery(wbPath: string, query: string): Promise<void> {
  if (!existsSync(wbPath)) {
    throw new Error(
      `No installed book at "${wbPath}". Author a deck, then: brandnana book publish <slug> <deck.html>`,
    );
  }

  const html = await readFile(wbPath, "utf8");

  // Extract wb-source-bundle.
  const MARKER_OPEN = '<script id="wb-source-bundle"';
  const MARKER_CLOSE = "</script>";
  const start = html.indexOf(MARKER_OPEN);
  if (start < 0) throw new Error("No wb-source-bundle block found in workbook.");
  const tagEnd = html.indexOf(">", start);
  const close = html.indexOf(MARKER_CLOSE, tagEnd);
  const b64 = html.slice(tagEnd + 1, close).replace(/\s/g, "");

  // The wb-source-bundle is base64(gzip(JSON)) — a single gunzip to JSON.
  const manifest = JSON.parse(gunzipSync(Buffer.from(b64, "base64")).toString("utf8")) as {
    files: Array<{ path: string; content?: string; truncated?: boolean }>;
  };

  // Collect all org files.
  const orgFiles = manifest.files.filter((f) => f.path.endsWith(".org") && !f.truncated && f.content);

  if (orgFiles.length === 0) {
    say("(no org files found in source bundle)");
    return;
  }

  const allHeadlines: OrgHeadline[] = [];
  for (const f of orgFiles) {
    const text = Buffer.from(f.content ?? "", "base64").toString("utf8");
    allHeadlines.push(...parseOrgHeadlines(text));
  }

  const results = applyOqlQuery(allHeadlines, query);

  if (results.length === 0) {
    say("(no results)");
    return;
  }

  for (const h of results) {
    const tagStr = h.tags.length > 0 ? `  :${h.tags.join(":")}:` : "";
    say(`${"*".repeat(h.level)} ${h.title}${tagStr}`);
    for (const [k, v] of Object.entries(h.props)) {
      say(`  :${k}: ${v}`);
    }
  }

  // Print the count quietly. Show the oql install tip ONCE per session
  // (tracked via a temp marker file) instead of on every query — was noise.
  const countLine = `\n(${results.length} result${results.length === 1 ? "" : "s"})`;
  const marker = "/tmp/.brandnana-oql-tip-shown";
  let tipShown = false;
  try {
    require("node:fs").accessSync(marker);
    tipShown = true;
  } catch {
    /* not shown yet */
  }
  if (!tipShown) {
    try {
      require("node:fs").writeFileSync(marker, String(Date.now()));
    } catch {
      /* ignore */
    }
    say(`${countLine}\n(for richer queries, install the oql CLI: brew install workbooks-sh/tap/oql)`);
  } else {
    say(countLine);
  }
}
