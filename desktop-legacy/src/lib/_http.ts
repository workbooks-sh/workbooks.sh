/**
 * Shared HTTP helpers for the broker client layers (network + share).
 * Keeps the error-envelope parser in one place so both clients decode
 * the broker's `{ error }` body identically.
 */

import { NetworkClientError } from "$lib/network/client";

/** Parse a non-ok Response into a NetworkClientError, preferring the
 *  broker's `{ error }` envelope and falling back to status text. */
export async function asError(r: Response): Promise<NetworkClientError> {
  let body: unknown = null;
  try {
    body = await r.json();
  } catch {
    body = await r.text().catch(() => null);
  }
  const errMsg =
    body && typeof body === "object" && body !== null && "error" in body
      ? String((body as { error: unknown }).error)
      : `HTTP ${r.status}`;
  return new NetworkClientError(errMsg, r.status, body);
}
