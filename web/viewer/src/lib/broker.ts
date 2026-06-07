/**
 * Broker client for apps/viewer. Public, no-auth endpoints only.
 *
 * The viewer is anonymous-by-default — recipients open a workbook
 * link without signing in. We only call Broker for:
 *   - resolveDid (DID → handle + WorkOS-verified name for the
 *     provenance badge)
 *   - listCatalog (public discoverable shares, for the browse grid)
 *
 * Heavier endpoints (publishing, friend graph, etc.) belong to
 * apps/desktop's client.ts and aren't surfaced here.
 */

const DEFAULT_BROKER_URL = "https://auth.workbooks.sh";

export interface IdentityView {
  handle: string;
  did: string;
  display_name: string | null;
  workos_display_name: string | null;
  created_at: number;
  updated_at: number;
}

export interface CatalogEntry {
  id: string;
  from_handle: string;
  rid: string;
  artifact_kind: "workbook" | "agent" | "plugin" | "skill";
  message: string | null;
  posture: "public" | "friends" | "group" | "private";
  featured_at: number | null;
  created_at: number;
}

export interface CatalogPage {
  items: CatalogEntry[];
  next_cursor: string | null;
}

function brokerUrl(): string {
  // Vite injects PUBLIC_BROKER_URL at build time. Default to prod.
  return (
    (import.meta.env as Record<string, string | undefined>)
      ?.PUBLIC_BROKER_URL ?? DEFAULT_BROKER_URL
  );
}

/** DID → identity lookup. Returns null on 404. */
export async function resolveDid(
  did: string,
  fetchImpl: typeof fetch = fetch,
): Promise<IdentityView | null> {
  const r = await fetchImpl(
    `${brokerUrl()}/v1/network/resolve-did/${encodeURIComponent(did)}`,
  );
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`broker resolve-did ${r.status}`);
  return r.json();
}

/** Public catalog of discoverable+public shares. */
export async function listCatalog(
  opts: { cursor?: string | null; limit?: number } = {},
  fetchImpl: typeof fetch = fetch,
): Promise<CatalogPage> {
  const qs = new URLSearchParams();
  if (opts.cursor) qs.set("cursor", opts.cursor);
  if (opts.limit) qs.set("limit", String(opts.limit));
  const sep = qs.toString() ? "?" : "";
  const r = await fetchImpl(`${brokerUrl()}/v1/network/catalog${sep}${qs}`);
  if (!r.ok) throw new Error(`broker catalog ${r.status}`);
  return r.json();
}
