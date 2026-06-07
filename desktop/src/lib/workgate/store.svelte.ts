// Workgate frontend store (wb-80q0.10).
//
// Holds the queue of pending Workgate.Request events pushed by the
// Elixir runtime over the `workgate:control` Phoenix channel.
//
// Flow:
//   1. WsBridgeStore receives a `workgate_request` event on the
//      `workgate:control` channel and calls `workgate.enqueue(req)`.
//   2. The store appends to `pending` and updates `current` to point
//      at the head.
//   3. WorkgateModal subscribes via `$derived` on `workgate.current`
//      and renders the approval prompt.
//   4. User clicks Allow/Deny → modal calls `workgate.respond(...)`.
//   5. Store calls back into WsBridgeStore to push the `permit`
//      message; then advances to the next pending (if any).
//
// One-modal-at-a-time semantics by construction: the modal only
// renders when `current != null` and we only advance after the
// user responds. No concurrent prompts; users approve them one at
// a time, in arrival order.

export type RememberKind = "one_time" | "this_session" | "this_workspace";

/** Minimal interface the store needs from the WS bridge. Defined
 *  here (rather than imported) to avoid a circular ESM dependency:
 *  the ws bridge already imports this store to enqueue requests. */
export interface WorkgatePushSink {
  workgatePermit(decision: WorkgatePermitDecision): Promise<void>;
}

/** Wire shape pushed by Workbooks.Engine.Web.WorkgateChannel under event name
 *  `workgate_request`. Mirrors the BEAM-side Permit/Request structs in
 *  packages/oql/elixir/oql-agent/lib/oql_agent/workgate/. */
export interface WorkgateRequest {
  id: string;
  workspace: string | null;
  session: string | null;
  capability: string;
  scope: Record<string, unknown>;
  reason: string;
  policy_decision: "prompt_user" | "allow" | "deny" | null;
  requested_at: string;
}

/** What we push back through the channel as the "permit" message. */
export interface WorkgatePermitDecision {
  request_id: string;
  granted: boolean;
  capability: string;
  scope: Record<string, unknown>;
  remember: RememberKind;
  expires_at: string | null;
}

class WorkgateStore {
  // Queue of requests waiting on user input. Head is rendered.
  pending = $state<WorkgateRequest[]>([]);

  // Convenience derived getter — the head of `pending`, or null when
  // the queue is empty (modal stays hidden).
  current = $derived(this.pending[0] ?? null);

  // Set lazily once the WS bridge mounts; receives our outbound
  // decisions and forwards to the Phoenix channel.
  #bridge: WorkgatePushSink | null = null;

  /** Wire the store to its WS bridge. Called from ws.svelte.ts on
   *  module load. */
  bindBridge(bridge: WorkgatePushSink) {
    this.#bridge = bridge;
  }

  /** Called by WsBridgeStore's `workgate:control` channel handler
   *  when a new request arrives from the agent. */
  enqueue(req: WorkgateRequest) {
    // Dedup by id — if for some reason the channel re-broadcasts,
    // don't show the same prompt twice.
    if (this.pending.some((r) => r.id === req.id)) return;
    this.pending = [...this.pending, req];
  }

  /** User clicked Allow on the current prompt. */
  async allow(opts: { remember: RememberKind; expires_at?: string | null } = { remember: "one_time" }) {
    const req = this.current;
    if (!req) return;
    await this.#respond({
      request_id: req.id,
      granted: true,
      capability: req.capability,
      scope: req.scope,
      remember: opts.remember,
      expires_at: opts.expires_at ?? null,
    });
    this.#advance(req.id);
  }

  /** User clicked Deny. */
  async deny() {
    const req = this.current;
    if (!req) return;
    await this.#respond({
      request_id: req.id,
      granted: false,
      capability: req.capability,
      scope: req.scope,
      remember: "one_time",
      expires_at: null,
    });
    this.#advance(req.id);
  }

  /** Internal: send the decision through the bridge. */
  async #respond(decision: WorkgatePermitDecision) {
    if (!this.#bridge) {
      // No bridge yet — shouldn't happen in production, but in tests
      // (or on a misconfigured boot) we don't want to throw and
      // strand the modal.
      console.warn("[workgate] no bridge bound; decision discarded:", decision);
      return;
    }
    await this.#bridge.workgatePermit(decision);
  }

  #advance(handled_id: string) {
    this.pending = this.pending.filter((r) => r.id !== handled_id);
  }
}

export const workgate = new WorkgateStore();
