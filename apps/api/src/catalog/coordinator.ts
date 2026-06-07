// CrawlCoordinator — per-(tenant, domain) Durable Object that tracks
// in-flight catalog crawls. Used to dedupe concurrent crawls, refuse
// duplicate work, and serve a status endpoint that reports progress.
//
// Design notes:
//   - The actual crawl runs in the worker, not the DO. The DO is just
//     the source of truth for "is a crawl running and what's its state."
//     Streaming through a DO would mean buffering or teeing across
//     transports, which doubles the complexity for marginal value.
//   - DO key = `${tenant}/${domain}`. Different tenants asking for the
//     same domain do NOT share state (could revisit if we want
//     cross-tenant caching of public-data crawls; out of scope here).
//   - The "active" window is `STALE_AFTER_MS`. If the last heartbeat
//     was older than that, we treat the prior crawl as dead and let a
//     new one start.

const STALE_AFTER_MS = 5 * 60 * 1000; // 5 minutes — bigger than any worker invocation

export interface CrawlState {
  status: "running" | "complete" | "failed" | "idle";
  /** Opaque id of the worker invocation that started this crawl. */
  crawl_id: string | null;
  strategy: string | null;
  started_at: number | null;
  last_heartbeat_at: number | null;
  finished_at: number | null;
  products: number;
  images: number;
  pages_fetched: number;
  errors: string[];
}

interface StartRequest {
  action: "start";
  crawl_id: string;
  strategy: string;
}

interface UpdateRequest {
  action: "update";
  crawl_id: string;
  products?: number;
  images?: number;
  pages_fetched?: number;
}

interface FinishRequest {
  action: "finish";
  crawl_id: string;
  errors: string[];
  status: "complete" | "failed";
}

/** Force-replace the active slot with a new crawl, regardless of whether
 * one is currently "running". Used when an agent escalates the strategy on
 * the SAME domain (auto-cascade retry / force=true) so /status tracks the
 * LIVE attempt instead of a stale slot whose crawl_id no longer matches
 * the heartbeats. */
interface ReclaimRequest {
  action: "reclaim";
  crawl_id: string;
  strategy: string;
}

type CoordinatorRequest =
  | StartRequest
  | UpdateRequest
  | FinishRequest
  | ReclaimRequest
  | { action: "status" };

interface StartResponse {
  ok: true;
  state: CrawlState;
}

interface ConflictResponse {
  ok: false;
  reason: "in_progress";
  state: CrawlState;
}

interface AckResponse {
  ok: true;
}

interface StatusResponse {
  ok: true;
  state: CrawlState;
}

export class CrawlCoordinator implements DurableObject {
  private state: DurableObjectState;
  private current: CrawlState = emptyState();

  constructor(state: DurableObjectState) {
    this.state = state;
    state.blockConcurrencyWhile(async () => {
      const stored = await state.storage.get<CrawlState>("state");
      if (stored) this.current = stored;
    });
  }

  async fetch(req: Request): Promise<Response> {
    const body = (await req.json().catch(() => null)) as CoordinatorRequest | null;
    if (!body || typeof body.action !== "string") {
      return json({ error: "missing_action" }, 400);
    }
    switch (body.action) {
      case "start":
        return this.handleStart(body);
      case "reclaim":
        return this.handleReclaim(body);
      case "update":
        return this.handleUpdate(body);
      case "finish":
        return this.handleFinish(body);
      case "status":
        return json<StatusResponse>({ ok: true, state: this.current });
      default:
        return json({ error: "unknown_action" }, 400);
    }
  }

  /** Unconditionally install a new running crawl, sealing whatever was
   * there before. Always succeeds — this is the strategy-retry path, where
   * the caller has already decided to supersede the prior attempt. */
  private async handleReclaim(req: ReclaimRequest): Promise<Response> {
    const now = Date.now();
    this.current = {
      status: "running",
      crawl_id: req.crawl_id,
      strategy: req.strategy,
      started_at: now,
      last_heartbeat_at: now,
      finished_at: null,
      products: 0,
      images: 0,
      pages_fetched: 0,
      errors: [],
    };
    await this.state.storage.put("state", this.current);
    return json<StartResponse>({ ok: true, state: this.current });
  }

  private async handleStart(req: StartRequest): Promise<Response> {
    const now = Date.now();
    if (this.isActive(now)) {
      return json<ConflictResponse>({ ok: false, reason: "in_progress", state: this.current }, 409);
    }
    this.current = {
      status: "running",
      crawl_id: req.crawl_id,
      strategy: req.strategy,
      started_at: now,
      last_heartbeat_at: now,
      finished_at: null,
      products: 0,
      images: 0,
      pages_fetched: 0,
      errors: [],
    };
    await this.state.storage.put("state", this.current);
    return json<StartResponse>({ ok: true, state: this.current });
  }

  private async handleUpdate(req: UpdateRequest): Promise<Response> {
    if (this.current.crawl_id !== req.crawl_id) {
      // Late update from a crawl that's been superseded; ignore.
      return json<AckResponse>({ ok: true });
    }
    this.current.last_heartbeat_at = Date.now();
    if (typeof req.products === "number") this.current.products = req.products;
    if (typeof req.images === "number") this.current.images = req.images;
    if (typeof req.pages_fetched === "number") this.current.pages_fetched = req.pages_fetched;
    await this.state.storage.put("state", this.current);
    return json<AckResponse>({ ok: true });
  }

  private async handleFinish(req: FinishRequest): Promise<Response> {
    if (this.current.crawl_id !== req.crawl_id) {
      return json<AckResponse>({ ok: true });
    }
    this.current.status = req.status;
    this.current.errors = req.errors;
    this.current.finished_at = Date.now();
    this.current.last_heartbeat_at = this.current.finished_at;
    await this.state.storage.put("state", this.current);
    return json<AckResponse>({ ok: true });
  }

  private isActive(now: number): boolean {
    if (this.current.status !== "running") return false;
    if (this.current.last_heartbeat_at === null) return false;
    return now - this.current.last_heartbeat_at < STALE_AFTER_MS;
  }
}

function emptyState(): CrawlState {
  return {
    status: "idle",
    crawl_id: null,
    strategy: null,
    started_at: null,
    last_heartbeat_at: null,
    finished_at: null,
    products: 0,
    images: 0,
    pages_fetched: 0,
    errors: [],
  };
}

function json<T>(body: T, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// --- Client helpers (worker-side) ----------------------------------------

export interface CoordinatorBinding {
  idFromName(name: string): DurableObjectId;
  get(id: DurableObjectId): DurableObjectStub;
}

function stubFor(binding: CoordinatorBinding, tenant: string, domain: string): DurableObjectStub {
  return binding.get(binding.idFromName(`${tenant}/${domain.toLowerCase()}`));
}

/** Try to claim a crawl slot for (tenant, domain). Returns {ok:true} on
 * success and the worker should proceed with the crawl; returns
 * {ok:false, state} if another crawl is already in-flight and the caller
 * should bail out or report the existing progress. */
export async function claimCrawl(
  binding: CoordinatorBinding,
  tenant: string,
  domain: string,
  crawlId: string,
  strategy: string,
): Promise<{ ok: true; state: CrawlState } | { ok: false; state: CrawlState }> {
  const stub = stubFor(binding, tenant, domain);
  const res = await stub.fetch("https://do/start", {
    method: "POST",
    body: JSON.stringify({ action: "start", crawl_id: crawlId, strategy }),
  });
  const body = (await res.json()) as { ok: boolean; state: CrawlState };
  return body.ok ? { ok: true, state: body.state } : { ok: false, state: body.state };
}

/** Force-install a new crawl slot for (tenant, domain), superseding any
 * stale `running` slot. Use on the strategy-retry / force path so /status
 * tracks the live attempt. Always resolves to the new state. */
export async function reclaimCrawl(
  binding: CoordinatorBinding,
  tenant: string,
  domain: string,
  crawlId: string,
  strategy: string,
): Promise<CrawlState> {
  const stub = stubFor(binding, tenant, domain);
  const res = await stub.fetch("https://do/reclaim", {
    method: "POST",
    body: JSON.stringify({ action: "reclaim", crawl_id: crawlId, strategy }),
  });
  const body = (await res.json()) as { state: CrawlState };
  return body.state;
}

export async function heartbeatCrawl(
  binding: CoordinatorBinding,
  tenant: string,
  domain: string,
  crawlId: string,
  counters: { products?: number; images?: number; pages_fetched?: number },
): Promise<void> {
  const stub = stubFor(binding, tenant, domain);
  await stub
    .fetch("https://do/update", {
      method: "POST",
      body: JSON.stringify({ action: "update", crawl_id: crawlId, ...counters }),
    })
    .catch(() => {});
}

export async function finishCrawl(
  binding: CoordinatorBinding,
  tenant: string,
  domain: string,
  crawlId: string,
  status: "complete" | "failed",
  errors: string[],
): Promise<void> {
  const stub = stubFor(binding, tenant, domain);
  await stub
    .fetch("https://do/finish", {
      method: "POST",
      body: JSON.stringify({ action: "finish", crawl_id: crawlId, status, errors }),
    })
    .catch(() => {});
}

export async function readCrawlStatus(
  binding: CoordinatorBinding,
  tenant: string,
  domain: string,
): Promise<CrawlState> {
  const stub = stubFor(binding, tenant, domain);
  const res = await stub.fetch("https://do/status", {
    method: "POST",
    body: JSON.stringify({ action: "status" }),
  });
  const body = (await res.json()) as { state: CrawlState };
  return body.state;
}
