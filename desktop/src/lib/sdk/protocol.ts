// Browser SDK protocol (wb-aakl.15) — the membrane between a dock-mounted
// toolkit UI (an iframe) and the host browser.
//
// Three message kinds flow over postMessage, all tagged by `type`:
//   wb-sdk-call   toolkit → host   { id, method, args }
//   wb-sdk-reply  host → toolkit   { id, ok, result? , error? }
//   wb-sdk-event  host → toolkit   { event, payload }
// (plus the pre-existing wb-theme / wb-theme-ready handshake, kept as-is.)
//
// The method surface is deliberately small + safe: it exposes only what the
// user can already do in the UI (tabs, bookmarks, workspace/viewer reads,
// the active nexus), never raw fs/exec. Toolkits own behavior; the host
// exposes seams (behavior-belongs-in-config-layer canon).

export const SDK_CALL = "wb-sdk-call";
export const SDK_REPLY = "wb-sdk-reply";
export const SDK_EVENT = "wb-sdk-event";

export interface SdkCall {
  type: typeof SDK_CALL;
  id: string;
  method: string;
  args?: unknown[];
}
export interface SdkReply {
  type: typeof SDK_REPLY;
  id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
}
export interface SdkEvent {
  type: typeof SDK_EVENT;
  event: SdkEventName;
  payload: unknown;
}

export type SdkEventName = "tab-changed" | "workbook-opened" | "theme-changed";

/** The callable method names, namespaced. Kept in sync with the host
 *  dispatcher (browserSdk.ts) and documented in docs/browser-sdk.md. */
export const SDK_METHODS = [
  "tabs.list",
  "tabs.active",
  "tabs.open",
  "tabs.focus",
  "tabs.close",
  "bookmarks.list",
  "bookmarks.add",
  "bookmarks.remove",
  "workspace.active",
  "workspace.list",
  "package.active",
  "viewer.current",
  "nexus.active",
  "theme.tokens",
] as const;

export type SdkMethod = (typeof SDK_METHODS)[number];
