// Env request frontend store — wb env request's desktop surface.
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

/** Minimal interface the store needs from the WS bridge. Defined here
 *  to keep the store independent of bridge internals. */
export interface EnvRequestPushSink {
  envFulfill(payload: EnvFulfillPayload): Promise<void>;
  envCancel(payload: EnvCancelPayload): Promise<void>;
}

class EnvRequestStore {
  // Queue of in-flight requests. Head is rendered.
  pending = $state<EnvRequest[]>([]);

  current = $derived(this.pending[0] ?? null);

  #bridge: EnvRequestPushSink | null = null;

  bindBridge(bridge: EnvRequestPushSink) {
    this.#bridge = bridge;
  }

  /** Called by WsBridgeStore's `engine:env_prompt` channel handler. */
  enqueue(req: EnvRequest) {
    if (this.pending.some((r) => r.id === req.id)) return;
    this.pending = [...this.pending, req];
  }

  /** User clicked Provide. `locked` overrides the request's default. */
  async fulfill(value: string, locked: boolean) {
    const req = this.current;
    if (!req) return;
    await this.#bridge?.envFulfill({
      request_id: req.id,
      value,
      locked,
    });
    this.#advance(req.id);
  }

  /** User clicked Cancel. */
  async cancel() {
    const req = this.current;
    if (!req) return;
    await this.#bridge?.envCancel({ request_id: req.id });
    this.#advance(req.id);
  }

  #advance(handled_id: string) {
    this.pending = this.pending.filter((r) => r.id !== handled_id);
  }
}

export const envRequests = new EnvRequestStore();
