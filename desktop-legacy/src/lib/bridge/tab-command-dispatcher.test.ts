// wb-i38o.11 — Tests for the desktop-side tab_command dispatcher.
// Stays in pure-TS land: no Svelte runtime, no Phoenix client, no
// Tauri runtime. The production bridge composes the same dispatcher
// with handlers backed by the live tabs store.

import { describe, it, expect, vi } from "vitest";
import {
  dispatchTabCommand,
  type TabCommandHandlers,
  type TabCommandPayload,
} from "./tab-command-dispatcher";

function mkHandlers(overrides: Partial<TabCommandHandlers> = {}): TabCommandHandlers {
  return {
    open: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    focus: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

describe("dispatchTabCommand", () => {
  it("routes 'open' to the open handler with the path", async () => {
    const h = mkHandlers();
    const p: TabCommandPayload = {
      action: "open",
      path: "/abs/x.org",
      session_id: "s-1",
    };
    const r = await dispatchTabCommand(p, h);
    expect(r).toEqual({ ok: true, action: "open", path: "/abs/x.org" });
    expect(h.open).toHaveBeenCalledWith("/abs/x.org");
    expect(h.close).not.toHaveBeenCalled();
    expect(h.focus).not.toHaveBeenCalled();
  });

  it("routes 'close' to the close handler", async () => {
    const h = mkHandlers();
    await dispatchTabCommand(
      { action: "close", path: "/abs/y.org", session_id: null },
      h,
    );
    expect(h.close).toHaveBeenCalledWith("/abs/y.org");
    expect(h.open).not.toHaveBeenCalled();
  });

  it("routes 'focus' to the focus handler", async () => {
    const h = mkHandlers();
    await dispatchTabCommand(
      { action: "focus", path: "/abs/z.org", session_id: null },
      h,
    );
    expect(h.focus).toHaveBeenCalledWith("/abs/z.org");
    expect(h.open).not.toHaveBeenCalled();
  });

  it("returns ok:false with 'unknown_action' for a bad action and does not invoke any handler", async () => {
    const h = mkHandlers();
    const bad = {
      action: "vaporize" as unknown as "open",
      path: "/x",
      session_id: null,
    };
    const r = await dispatchTabCommand(bad, h);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("unknown_action");
    expect(h.open).not.toHaveBeenCalled();
    expect(h.close).not.toHaveBeenCalled();
    expect(h.focus).not.toHaveBeenCalled();
  });

  it("returns ok:false when the handler rejects", async () => {
    const h = mkHandlers({
      open: vi.fn().mockRejectedValue(new Error("tab_open failed")),
    });
    const r = await dispatchTabCommand(
      { action: "open", path: "/abs/x.org", session_id: null },
      h,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(/tab_open failed/);
  });
});
