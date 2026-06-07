import type { ParamMatcher } from "@sveltejs/kit";

/** Live URL slug matcher.
 *
 *  Must stay in sync with services/broker/worker/src/routes/rooms.ts
 *  (SLUG_RE) and the broker's randomBase64Url(8) issuance shape. The
 *  8-char minimum is what keeps top-level /:slug from colliding with
 *  the static routes (/w, /install, /, etc) — none of those clear the
 *  length floor. */
export const match: ParamMatcher = (param) => {
  return /^[A-Za-z0-9_-]{8,32}$/.test(param);
};
