/**
 * Per-tab share state (wb-v9ys.3).
 *
 * Keyed by the workbook's local file path. Each entry tracks:
 *   - workbook_id: stable broker ID, persisted in a sidecar JSON
 *   - rooms:       the broker's view of this workbook's rooms
 *   - status:      UI state machine
 *
 * Sidecar shape (lives next to the .html as `<path>.wb-share.json`):
 *   { workbook_id: string, registered_at: number }
 *
 * The sidecar is the local ↔ broker mapping. Moving the .html without
 * the sidecar effectively "forgets" the share — that's acceptable for
 * v1 (per plans/live-urls.org decision A). A future iteration could
 * embed the ID in the .html itself.
 */

import { invoke } from "@tauri-apps/api/core";
import {
  registerWorkbook,
  putArtifact,
  createRoom,
  listRoomsForWorkbook,
  patchRoom,
  deleteRoom,
  listComments,
  setCommentResolved,
  deleteCommentRow,
  fetchTierLimits,
  type RoomAccessMode,
  type RoomView,
  type CommentView,
  type TierReadback,
} from "$lib/share/client";
import { DemoModeError, getBrokerUrl } from "$lib/network/client";

/** A live peer in the room — name + color chip in the Share drawer's
 *  "Watching now" section. */
export interface RoomPeer {
  peer_id: string;
  name: string;
  color: string;
}

export type ShareStatus =
  | "unknown"        // we haven't checked the sidecar yet
  | "unshared"       // sidecar absent — no broker workbook_id yet
  | "sharing"        // an action is in flight (register / upload / mint / patch)
  | "shared"         // sidecar present + rooms loaded
  | "demo"           // broker unreachable (demo mode or not signed in)
  | "error";         // last action threw; see error field

export interface TabShareState {
  workbook_id: string | null;
  rooms: RoomView[];
  /** Per-slug comment thread. Keyed by room.slug; missing means
   *  "not loaded yet" (UI shows a "Load comments" affordance). */
  comments: Record<string, CommentView[]>;
  /** Per-slug live peer roster from the presence WS. */
  peers: Record<string, RoomPeer[]>;
  status: ShareStatus;
  error: string | null;
}

function emptyState(): TabShareState {
  return { workbook_id: null, rooms: [], comments: {}, peers: {}, status: "unknown", error: null };
}

function sidecarPath(workbookPath: string): string {
  return `${workbookPath}.wb-share.json`;
}

interface SidecarShape {
  workbook_id: string;
  registered_at: number;
}

function rb64u(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function newWorkbookId(): string {
  return `wb_${rb64u(crypto.getRandomValues(new Uint8Array(9)))}`;
}

class ShareStore {
  /** path → state. Reactive: components subscribe by reading this[path]. */
  private byPath = $state<Record<string, TabShareState>>({});
  /** Account-wide tier readback (wb-v9ys.7). Loaded lazily on the
   *  first drawer open. The same value is used by every workbook tab,
   *  so we cache it at the store level. */
  tier = $state<TierReadback | null>(null);

  async loadTier(): Promise<void> {
    try {
      this.tier = await fetchTierLimits();
    } catch {
      // Demo mode / no session → leave null; drawer treats null as
      // "limits unknown" and renders neutral copy.
      this.tier = null;
    }
  }

  /** Reactive accessor — READ-ONLY. Never mutates `byPath`, so it is
   *  safe to call from inside a `$derived` (a lazy-init write here was
   *  the source of a `state_unsafe_mutation` crash when ShareButton
   *  derived off an as-yet-unseen workbook path). Returns the live
   *  reactive ref when present, else a fresh default snapshot. State is
   *  materialised by `ensure()` from the explicit lifecycle methods. */
  get(path: string): TabShareState {
    return this.byPath[path] ?? emptyState();
  }

  /** Return-or-init the live reactive ref. Used by the mutating
   *  lifecycle methods (hydrate / share / …) — never from a derived. */
  private ensure(path: string): TabShareState {
    if (!this.byPath[path]) this.byPath[path] = emptyState();
    return this.byPath[path];
  }

  /** Sync version for callers that need a snapshot (eg. for diff
   *  decisions before initiating an action). */
  snapshot(path: string): TabShareState {
    return { ...(this.byPath[path] ?? emptyState()) };
  }

  /** Read the sidecar if it exists. If present, sets state to "shared"
   *  and refreshes the room list from the broker. If absent, sets
   *  "unshared". Idempotent — safe to call on every tab open. */
  async hydrate(workbookPath: string): Promise<void> {
    const st = this.ensure(workbookPath);
    if (st.status === "sharing") return; // mid-flight; let it finish
    st.error = null;

    let sidecar: SidecarShape | null = null;
    try {
      const raw = await invoke<string>("read_file_text", {
        path: sidecarPath(workbookPath),
      });
      sidecar = JSON.parse(raw) as SidecarShape;
    } catch {
      // Most common case: file doesn't exist. Treat any read failure
      // as "unshared" — we don't want a corrupt sidecar to lock the
      // user out of re-sharing.
      sidecar = null;
    }

    if (!sidecar) {
      st.workbook_id = null;
      st.rooms = [];
      st.status = "unshared";
      return;
    }

    st.workbook_id = sidecar.workbook_id;

    // Refresh rooms from broker. Demo mode → surface that explicitly
    // so the drawer can show "Sign in to share".
    try {
      const rooms = await listRoomsForWorkbook(sidecar.workbook_id);
      st.rooms = rooms;
      st.status = "shared";
    } catch (err) {
      if (err instanceof DemoModeError) {
        st.status = "demo";
        return;
      }
      st.status = "error";
      st.error = err instanceof Error ? err.message : String(err);
    }
  }

  /** First-time share: generate ID, register workbook, upload artifact,
   *  mint a room, persist the sidecar. Returns the new room. */
  async createFirstRoom(
    workbookPath: string,
    opts: { access_mode?: RoomAccessMode; password?: string } = {},
  ): Promise<RoomView> {
    const st = this.ensure(workbookPath);
    st.status = "sharing";
    st.error = null;
    try {
      // 1. Generate / claim a workbook_id.
      let workbook_id = st.workbook_id;
      if (!workbook_id) {
        workbook_id = newWorkbookId();
        await registerWorkbook({ workbook_id });
        st.workbook_id = workbook_id;
        // 2. Persist the sidecar BEFORE the heavy lift so a half-
        //    finished upload still binds the ID for retry.
        const sidecar: SidecarShape = {
          workbook_id,
          registered_at: Math.floor(Date.now() / 1000),
        };
        await invoke("file_save", {
          path: sidecarPath(workbookPath),
          contents: JSON.stringify(sidecar, null, 2) + "\n",
        });
      }

      // 3. Upload the .html bytes.
      const html = await invoke<string>("read_file_text", { path: workbookPath });
      await putArtifact({ workbook_id, html });

      // 4. Mint the room.
      const room = await createRoom({
        workbook_id,
        access_mode: opts.access_mode ?? "link",
        password: opts.password,
      });
      st.rooms = [...st.rooms, room];
      st.status = "shared";
      return room;
    } catch (err) {
      if (err instanceof DemoModeError) {
        st.status = "demo";
        throw err;
      }
      st.status = "error";
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }

  /** Push the current .html bytes as a new artifact for an already-
   *  shared workbook. All enabled rooms immediately serve the new
   *  bytes (see plans/live-urls.org §release model). */
  async release(workbookPath: string): Promise<void> {
    const st = this.ensure(workbookPath);
    if (!st.workbook_id) throw new Error("release_called_without_workbook_id");
    st.status = "sharing";
    st.error = null;
    try {
      const html = await invoke<string>("read_file_text", { path: workbookPath });
      await putArtifact({ workbook_id: st.workbook_id, html });
      st.status = "shared";
    } catch (err) {
      st.status = "error";
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }

  async toggleEnabled(workbookPath: string, slug: string, enabled: boolean): Promise<void> {
    const st = this.ensure(workbookPath);
    st.error = null;
    try {
      const updated = await patchRoom({ slug, enabled });
      st.rooms = st.rooms.map((r) => (r.slug === slug ? updated : r));
    } catch (err) {
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }

  /** Change the room's access mode (and password, when relevant). */
  async setAccess(
    workbookPath: string,
    slug: string,
    args: { access_mode: RoomAccessMode; password?: string },
  ): Promise<void> {
    const st = this.ensure(workbookPath);
    st.error = null;
    try {
      const updated = await patchRoom({ slug, ...args });
      st.rooms = st.rooms.map((r) => (r.slug === slug ? updated : r));
    } catch (err) {
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }

  async destroy(workbookPath: string, slug: string): Promise<void> {
    const st = this.ensure(workbookPath);
    st.error = null;
    try {
      await deleteRoom(slug);
      st.rooms = st.rooms.filter((r) => r.slug !== slug);
    } catch (err) {
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }

  /** Drop the in-memory entry — called on tab close so the next open
   *  re-hydrates fresh. */
  forget(workbookPath: string): void {
    delete this.byPath[workbookPath];
    // Tear down any room subscriptions whose primaryRoom belonged to
    // this path. Conservative: the channels.byPath map below tracks
    // ownership; we just close any that match the path.
    for (const slug of Object.keys(this.channels)) {
      if (this.channels[slug]?.path === workbookPath) {
        try { this.channels[slug].ws.close(); } catch { /* */ }
        delete this.channels[slug];
      }
    }
  }

  // ── Live room channels (wb-v9ys.6) ─────────────────────────────
  // Each Share drawer subscribes to the room WS. The store owns the
  // connection so the drawer can close/reopen without losing state.
  // We use the owner-bypass on the broker side — cookies-included.

  private channels: Record<string, { ws: WebSocket; path: string }> = {};

  /** Open a presence WS for a slug. Idempotent — re-opens after a
   *  disconnect. Roster lands in state.peers[slug]; comment events
   *  patch state.comments[slug]. */
  subscribe(workbookPath: string, slug: string): void {
    if (this.channels[slug]) return;
    const broker = getBrokerUrl();
    const wsBase = broker.replace(/^http/, "ws");
    const url = `${wsBase}/v1/rooms/${encodeURIComponent(slug)}/ws`;
    const ws = new WebSocket(url);
    this.channels[slug] = { ws, path: workbookPath };

    ws.addEventListener("open", () => {
      // Owner identifies as itself; the broker doesn't surface the
      // owner in roster broadcasts but the WS still has to send
      // presence.hello to be considered "joined".
      ws.send(JSON.stringify({
        type: "presence.hello",
        name: "Owner",
        color: "#888888",
      }));
    });

    ws.addEventListener("message", (ev) => {
      let m: { type?: string; [k: string]: unknown };
      try { m = JSON.parse(ev.data.toString()); }
      catch { return; }
      this.handleWsEvent(workbookPath, slug, m);
    });

    ws.addEventListener("close", () => {
      delete this.channels[slug];
      // No auto-reconnect for desktop — the drawer remounts when the
      // user re-opens it, which triggers a fresh subscribe.
    });
  }

  unsubscribe(slug: string): void {
    const ch = this.channels[slug];
    if (!ch) return;
    try { ch.ws.close(); } catch { /* */ }
    delete this.channels[slug];
  }

  private handleWsEvent(
    workbookPath: string,
    slug: string,
    m: { type?: string; [k: string]: unknown },
  ): void {
    const st = this.ensure(workbookPath);
    switch (m.type) {
      case "presence.list": {
        const peers = (m.peers as RoomPeer[] | undefined) ?? [];
        st.peers = { ...st.peers, [slug]: peers.filter((p) => p.name !== "Owner") };
        return;
      }
      case "presence.join": {
        const p = m.peer as RoomPeer | undefined;
        if (!p || p.name === "Owner") return;
        const cur = st.peers[slug] ?? [];
        if (cur.some((x) => x.peer_id === p.peer_id)) return;
        st.peers = { ...st.peers, [slug]: [...cur, p] };
        return;
      }
      case "presence.bye": {
        const id = String(m.peer_id);
        const cur = st.peers[slug] ?? [];
        st.peers = { ...st.peers, [slug]: cur.filter((x) => x.peer_id !== id) };
        return;
      }
      case "comment.created": {
        const c = m.comment as CommentView | undefined;
        if (!c) return;
        const list = st.comments[slug] ?? [];
        if (list.some((x) => x.id === c.id)) return;
        st.comments = { ...st.comments, [slug]: [c, ...list] };
        return;
      }
      case "comment.updated": {
        const c = m.comment as CommentView | undefined;
        if (!c) return;
        const list = st.comments[slug] ?? [];
        st.comments = {
          ...st.comments,
          [slug]: list.map((x) => (x.id === c.id ? c : x)),
        };
        return;
      }
      case "comment.deleted": {
        const id = String(m.id);
        const list = st.comments[slug] ?? [];
        st.comments = {
          ...st.comments,
          [slug]: list.filter((x) => x.id !== id),
        };
        return;
      }
    }
  }

  // ── Comments ──────────────────────────────────────────────────────

  async loadComments(workbookPath: string, slug: string): Promise<void> {
    const st = this.ensure(workbookPath);
    st.error = null;
    try {
      const list = await listComments(slug);
      st.comments = { ...st.comments, [slug]: list };
    } catch (err) {
      st.error = err instanceof Error ? err.message : String(err);
    }
  }

  async toggleCommentResolved(
    workbookPath: string,
    slug: string,
    id: string,
    resolved: boolean,
  ): Promise<void> {
    const st = this.ensure(workbookPath);
    st.error = null;
    try {
      const updated = await setCommentResolved({ slug, id, resolved });
      const list = (st.comments[slug] ?? []).map((c) => (c.id === id ? updated : c));
      st.comments = { ...st.comments, [slug]: list };
    } catch (err) {
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }

  async removeComment(workbookPath: string, slug: string, id: string): Promise<void> {
    const st = this.ensure(workbookPath);
    st.error = null;
    try {
      await deleteCommentRow({ slug, id });
      const list = (st.comments[slug] ?? []).filter((c) => c.id !== id);
      st.comments = { ...st.comments, [slug]: list };
    } catch (err) {
      st.error = err instanceof Error ? err.message : String(err);
      throw err;
    }
  }
}

export const shareStore = new ShareStore();
