// workponents · auth domain — identity as a HOST capability.
//
// The reinvention: identity is provider-agnostic. The elements bind to ONE
// identity seam layered on `this.host` (`identity.js`) — Clerk / Auth0 / WorkOS /
// BetterAuth are server-side wirings behind it, surfaced through the same Dock,
// not a per-provider widget. Standalone (no Host/runtime) the seam serves a MOCK
// identity so the elements render + demo a full sign-in → authed → sign-out cycle
// with no backend.
//
// All three elements style only from --wb-* tokens, extend WbElement, register
// via define(), and reach identity through the seam (over this.host).
//
//   <work-auth>  — the sign-in surface (provider buttons + email/password|magic).
//   <work-user>  — avatar + identity menu, bound to the current session.
//   <work-gate>  — declarative auth guard (when="authed|anon|role:<x>" + fallback).
//
// Import this barrel for the whole auth set, or a single element file.
export { WorkAuth } from "./work-auth.js";
export { WorkUser } from "./work-user.js";
export { WorkGate } from "./work-gate.js";

// The identity seam (also usable standalone by a host wiring its own provider).
export {
  AuthCapability,
  getIdentity,
  configureIdentity,
  DEFAULT_PROVIDERS,
} from "./identity.js";
