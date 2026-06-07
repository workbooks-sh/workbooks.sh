// wb-i38o.9 / wb-i38o.10 — pure org → HTML pipeline.
//
// Extracted out of OrgView.svelte so D10's split editor can drive a
// preview pane straight from an in-memory source string (live re-
// render on keystroke) without going through Tauri.

import { getOql } from "./oql";
import {
  buildHeadingsWithProperties,
  injectHeadingChrome,
  transformGapComments,
  type ParsedHeadline,
} from "./transforms";

export async function renderOrg(source: string): Promise<string> {
  const oql = await getOql();
  const parsed = JSON.parse(oql.parseHeadlines(source)) as ParsedHeadline[];
  const headings = buildHeadingsWithProperties(source, parsed);
  let rendered = oql.renderHtml(source);
  rendered = transformGapComments(rendered);
  rendered = injectHeadingChrome(rendered, headings);
  return rendered;
}
