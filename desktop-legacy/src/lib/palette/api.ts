// AI command palette client (wb-5hc0.3).
//
// One function, one endpoint. The engine returns either a text
// answer to display in-modal, or a write payload to inject into the
// composer. No session, no streaming, no resumption.

import { sidecar } from "$lib/bridge/sidecar.svelte";

export type PaletteResult =
  | { mode: "answer"; text: string }
  | { mode: "write"; text: string };

export interface AskPaletteOptions {
  /** What's in the composer right now. Empty string is fine — used
   *  by the engine to pick "prelude" vs "enhance" framing. */
  composerText?: string;
  /** Absolute path of the active Package. The engine uses this to
   *  load plan.org + kanban-views.org as additional context. */
  workdir?: string | null;
}

/** Ask the workspace. Returns a discriminated result or throws on
 *  transport / engine error. Caller catches + surfaces an error
 *  state in the UI. */
export async function askPalette(
  prompt: string,
  opts: AskPaletteOptions = {},
): Promise<PaletteResult> {
  if (!sidecar.status.url) {
    throw new Error("Engine isn't ready yet.");
  }

  const res = await fetch(`${sidecar.status.url}/api/palette/ask`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify({
      prompt,
      composer_text: opts.composerText ?? "",
      workdir: opts.workdir ?? null,
    }),
  });

  const body = (await res.json().catch(() => null)) as
    | PaletteResult
    | { error: string; detail?: string }
    | null;

  if (!res.ok || !body) {
    const detail =
      body && "error" in body
        ? `${body.error}${body.detail ? ` — ${body.detail}` : ""}`
        : `HTTP ${res.status}`;
    throw new Error(detail);
  }

  if ("mode" in body && (body.mode === "answer" || body.mode === "write")) {
    return body;
  }

  throw new Error("Unexpected response shape from /api/palette/ask");
}
