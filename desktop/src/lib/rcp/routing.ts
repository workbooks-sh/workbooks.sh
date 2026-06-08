// RCP routing — a framework-agnostic route → posture resolver (sealed-bundle part
// b). PORTABLE (no Tauri/Svelte/framework imports). Any router (SvelteKit,
// TanStack Router, a hand-rolled one) plugs in: the resolver owns POSTURE +
// content/key; your framework owns navigation + rendering. Gated routes can't
// render because the content stays gated until the runtime releases it.
//
// Pure `resolve(path)` (no IO) decides routing; async `load(path)` performs the
// gated fetch through the RCP client and maps failures to a routing outcome.

import { RcpError } from "./types";
import type { RcpClient } from "./client";

export type Posture = "public" | "gated_data" | "gated_route";

export interface RouteDef {
  /** Exact path, or a `/prefix/*` wildcard. */
  pattern: string;
  posture: Posture;
  /** Runtime path to fetch the (possibly sealed) content for gated routes. */
  contentPath?: string;
}

export type RouteTable = RouteDef[];

export interface RoutePlan {
  status: "public" | "gated" | "not_found";
  posture?: Posture;
  contentPath?: string;
}

export type LoadResult =
  | { status: "ok"; content: unknown }
  | { status: "public"; content: null } // public route: render from the bundle, no fetch
  | { status: "denied"; reason: string } // runtime refused (auth/posture)
  | { status: "unavailable" } // runtime unreachable
  | { status: "not_found" };

/** First matching route (exact wins over wildcard; longest wildcard wins). */
export function matchRoute(table: RouteTable, path: string): RouteDef | null {
  const exact = table.find((r) => r.pattern === path);
  if (exact) return exact;
  const wilds = table
    .filter((r) => r.pattern.endsWith("/*") && path.startsWith(r.pattern.slice(0, -1)))
    .sort((a, b) => b.pattern.length - a.pattern.length);
  return wilds[0] ?? null;
}

export class RouteGate {
  #table: RouteTable;
  #client: RcpClient;
  constructor(table: RouteTable, client: RcpClient) {
    this.#table = table;
    this.#client = client;
  }

  /** Pure routing decision — no network. The router uses this to navigate. */
  resolve(path: string): RoutePlan {
    const def = matchRoute(this.#table, path);
    if (!def) return { status: "not_found" };
    if (def.posture === "public") return { status: "public", posture: "public", contentPath: def.contentPath };
    return { status: "gated", posture: def.posture, contentPath: def.contentPath };
  }

  /** Resolve + (for gated routes) fetch the content through the runtime, mapping
   *  the RCP error envelope onto a routing outcome the adapter acts on. */
  async load(path: string): Promise<LoadResult> {
    const plan = this.resolve(path);
    if (plan.status === "not_found") return { status: "not_found" };
    if (plan.status === "public") return { status: "public", content: null };
    if (!plan.contentPath) return { status: "denied", reason: "no contentPath for gated route" };
    try {
      const content = await this.#client.request(plan.contentPath);
      return { status: "ok", content };
    } catch (e) {
      if (e instanceof RcpError) {
        if (e.isUnavailable) return { status: "unavailable" };
        if (["unauthorized", "tenant_required", "forbidden"].includes(String(e.code)))
          return { status: "denied", reason: String(e.code) };
        if (e.code === "not_found") return { status: "not_found" };
      }
      return { status: "denied", reason: e instanceof Error ? e.message : "error" };
    }
  }
}
