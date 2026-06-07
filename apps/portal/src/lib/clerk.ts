// Server-side Clerk helpers. Wraps @clerk/backend so the rest of the app
// doesn't import the SDK directly. Cross-runtime safe — used in Cloudflare
// Workers via the SvelteKit adapter.

import { createClerkClient } from "@clerk/backend";
import type { ClerkClient } from "@clerk/backend";

let cached: ClerkClient | null = null;

export function getClerkClient(secretKey: string, publishableKey: string): ClerkClient {
  if (cached) return cached;
  cached = createClerkClient({ secretKey, publishableKey });
  return cached;
}

export const CLERK_SIGN_IN_PATH = "/app/auth/sign-in";
export const CLERK_SIGN_UP_PATH = "/app/auth/sign-up";
export const CLERK_AFTER_SIGN_IN_PATH = "/app";
export const CLERK_AFTER_SIGN_OUT_PATH = "/";
