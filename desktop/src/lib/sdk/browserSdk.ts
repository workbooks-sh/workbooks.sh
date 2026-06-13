// Browser SDK host dispatcher (wb-aakl.15).
//
// Maps SDK method names (protocol.ts) onto the real browser stores. This is
// the only place a toolkit's request touches host state — the surface is
// curated reads + the same mutations the UI performs, nothing more. Called
// by DockHost when a wb-sdk-call arrives from an iframe panel.

import { tabs } from "$lib/tabs/store.svelte";
import { bookmarks } from "$lib/bridge/bookmarks.svelte";
import { workspaces } from "$lib/bridge/workspaces.svelte";
import { packageStore } from "$lib/bridge/package.svelte";
import { nexus } from "$lib/bridge/nexus.svelte";
import { themes } from "$lib/bridge/themes.svelte";

function str(v: unknown): string {
  if (typeof v !== "string") throw new Error("expected a string argument");
  return v;
}

function currentTokens(): Record<string, string> {
  if (typeof document === "undefined") return {};
  const cs = getComputedStyle(document.documentElement);
  const out: Record<string, string> = {};
  for (const name of themes.appliedTokenNames()) {
    const v = cs.getPropertyValue(`--${name}`).trim();
    if (v) out[name] = v;
  }
  return out;
}

/** Dispatch a single SDK call. Throws on unknown method / bad args; the
 *  caller (DockHost) turns a throw into a wb-sdk-reply error. */
export async function dispatchSdk(method: string, args: unknown[] = []): Promise<unknown> {
  switch (method) {
    // ── tabs ──
    case "tabs.list":
      return tabs.tabs.map((t) => ({ id: t.id, path: t.path, title: t.title }));
    case "tabs.active":
      return tabs.active
        ? { id: tabs.active.id, path: tabs.active.path, title: tabs.active.title }
        : null;
    case "tabs.open":
      await tabs.open(str(args[0]));
      return { ok: true };
    case "tabs.focus":
      await tabs.focus(str(args[0]));
      return { ok: true };
    case "tabs.close":
      await tabs.close(str(args[0]));
      return { ok: true };

    // ── bookmarks ──
    case "bookmarks.list":
      return bookmarks.bookmarks.map((b) => ({ id: b.id, title: b.title, path: b.path }));
    case "bookmarks.add":
      await bookmarks.create(str(args[0]), str(args[1]), null);
      return { ok: true };
    case "bookmarks.remove":
      await bookmarks.delete(str(args[0]));
      return { ok: true };

    // ── workspace / package (reads) ──
    case "workspace.active":
      return workspaces.active
        ? { id: workspaces.active.id, name: workspaces.active.name }
        : null;
    case "workspace.list":
      return workspaces.workspaces.map((w) => ({ id: w.id, name: w.name }));
    case "package.active":
      return packageStore.active
        ? { name: packageStore.active.name }
        : null;

    // ── viewer ──
    case "viewer.current":
      return tabs.active ? { path: tabs.active.path, title: tabs.active.title } : null;

    // ── nexus (read) ──
    case "nexus.active":
      return { name: nexus.active.name, url: nexus.activeUrl, mode: nexus.active.mode };

    // ── theme ──
    case "theme.tokens":
      return currentTokens();

    default:
      throw new Error(`unknown SDK method: ${method}`);
  }
}
