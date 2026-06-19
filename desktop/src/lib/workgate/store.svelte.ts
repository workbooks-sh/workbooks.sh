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

/** Wire shape pushed by Workbooks.Engine.Web.WorkgateChannel under event name
 *  `workgate_request`. Mirrors the BEAM-side Permit/Request structs in
 *  runtime/host */
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

  /** Enqueue a new request (local-only; the runtime transport that
   *  used to push these over `workgate:control` is gone — the modal
   *  stays dormant until a local caller re-wires a source). */
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

  /** Internal: record the decision. The runtime transport that pushed
   *  permits back over `workgate:control` is gone; until a local sink
   *  is re-wired the decision is resolved in-process. */
  async #respond(_decision: WorkgatePermitDecision) {
    return;
  }

  #advance(handled_id: string) {
    this.pending = this.pending.filter((r) => r.id !== handled_id);
  }
}

export const workgate = new WorkgateStore();
