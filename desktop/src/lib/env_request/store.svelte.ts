// Env request frontend store — work env request's desktop surface.
//
// Holds the queue of pending Workbooks.Engine.EnvBroker requests
// pushed over the `engine:env_prompt` Phoenix channel. Same shape
// as the workgate store; specialized to the env-var case (value +
// locked instead of allow/deny + remember).
//
// Flow:
//   1. WsBridgeStore receives an `env_prompt` event on the
//      `engine:env_prompt` channel and calls `envRequests.enqueue(req)`.
//   2. The store appends to `pending`; `current` is the head.
//   3. EnvRequestModal renders when `current != null`.
//   4. User types the value + clicks Provide → modal calls
//      `envRequests.fulfill(value, locked)`.
//   5. Store pushes `env:fulfill` through the bridge; advances on ack.
//
// One-modal-at-a-time semantics, identical to workgate. Multiple
// pending requests queue up; the user answers them in arrival order.

export interface EnvRequest {
  id: string;
  name: string;
  workspace: string;
  reason: string | null;
  hint: string | null;
  locked: boolean;
}

export interface EnvFulfillPayload {
  request_id: string;
  value: string;
  locked: boolean;
}

export interface EnvCancelPayload {
  request_id: string;
}

class EnvRequestStore {
  // Queue of in-flight requests. Head is rendered.
  pending = $state<EnvRequest[]>([]);

  current = $derived(this.pending[0] ?? null);

  /** Enqueue a new request (local-only; the runtime transport that
   *  pushed these over `engine:env_prompt` is gone — the modal stays
   *  dormant until a local caller re-wires a source). */
  enqueue(req: EnvRequest) {
    if (this.pending.some((r) => r.id === req.id)) return;
    this.pending = [...this.pending, req];
  }

  /** User clicked Provide. `locked` overrides the request's default. */
  async fulfill(_value: string, _locked: boolean) {
    const req = this.current;
    if (!req) return;
    // Runtime transport gone — advance the queue locally.
    this.#advance(req.id);
  }

  /** User clicked Cancel. */
  async cancel() {
    const req = this.current;
    if (!req) return;
    this.#advance(req.id);
  }

  #advance(handled_id: string) {
    this.pending = this.pending.filter((r) => r.id !== handled_id);
  }
}

export const envRequests = new EnvRequestStore();
