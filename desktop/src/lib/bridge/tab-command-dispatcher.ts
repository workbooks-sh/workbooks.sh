// wb-i38o.11 — Pure dispatch helper for tab_command events received
// on the desktop:control Phoenix channel. Lifted out of ws.svelte.ts
// so it can be exercised in isolation by vitest without booting the
// Svelte runtime or the Phoenix client.
//
// The bridge composes this with the live `tabs` Svelte store; tests
// pass a stub.

export type TabCommandAction = "open" | "close" | "focus";

export interface TabCommandPayload {
  action: TabCommandAction;
  path: string;
  session_id: string | null;
}

export interface TabCommandHandlers {
  open: (path: string) => Promise<unknown>;
  close: (path: string) => Promise<unknown>;
  focus: (path: string) => Promise<unknown>;
}

export type TabCommandResult =
  | { ok: true; action: TabCommandAction; path: string }
  | { ok: false; reason: "unknown_action" | string; payload: TabCommandPayload };

/** Dispatch a tab_command payload to the appropriate handler. Returns
 *  a discriminated result instead of throwing so callers can decide
 *  whether to surface the error (the production bridge logs to the
 *  event ring; tests assert against the return value). */
export async function dispatchTabCommand(
  payload: TabCommandPayload,
  handlers: TabCommandHandlers,
): Promise<TabCommandResult> {
  const fn = handlers[payload.action];
  if (!fn) return { ok: false, reason: "unknown_action", payload };

  try {
    await fn(payload.path);
    return { ok: true, action: payload.action, path: payload.path };
  } catch (err) {
    return { ok: false, reason: String(err), payload };
  }
}
