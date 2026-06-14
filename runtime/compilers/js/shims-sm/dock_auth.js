/* Dock subscription-auth ops — StarlingMonkey eval lane (SLICE 3, wb-b9xv.7).
 *
 * The three primitives the in-wasm harness would otherwise get from native syscalls, exposed to the
 * harness as `require('dock-auth')` (also installed on globalThis.dock). The harness owns its OWN OAuth
 * state machine; we supply only:
 *
 *   dock.creds.get(provider)            -> Promise<string|null>   read the harness's opaque creds blob
 *   dock.creds.put(provider, blob)      -> Promise<boolean>       store the opaque blob (keychain-backed)
 *   dock.oauth.loopback({authorizeBase, codeChallenge, clientId?, scope?, state?})
 *                                       -> Promise<{code, redirectUri}>
 *
 * TRANSPORT: the SM lane has no host import surface beyond wasi:http; its only seam is a guest fetch().
 * So every op fetch()es the SAME fixed internal sentinel that child_process uses (`wb-exec.internal`,
 * pinned to the in-process ExecLoopback listener past the SSRF floor), with the SAME per-run grant token
 * in the `x-wb-exec` header. We derive the route URLs from `__wbExec.url` (…/__wb/exec) so no extra seam
 * plumbing is needed — one token, one pinned host, four routes. Absent grant => the ops throw / return
 * default-deny exactly like child_process.
 *
 * BYO + NO-POOL: the host fixes the (user) from the grant's creds_scope — never from anything this shim
 * sends — so the harness can only ever touch the user+provider the host granted. The blob is opaque (the
 * user's subscription token); it is stored in the user's keychain and flows only to the user's own
 * provider over the user's own fetch (NetGuard). PKCE lives ENTIRELY here: the harness generates the
 * verifier + S256 challenge in WebCrypto and sends only the CHALLENGE to the host, so the verifier never
 * crosses the membrane. */
"use strict";

function seam() {
  var c = (typeof globalThis !== "undefined" && globalThis.__wbExec) || null;
  if (!c || !c.url) throw new Error("dock-auth: capability unavailable (no grant on this run)");
  return c;
}

// Derive a sibling route from the exec sentinel URL (…/__wb/exec -> …/__wb/<route>).
function routeUrl(route) {
  var base = seam().url;
  return base.replace(/\/__wb\/exec$/, "/__wb/" + route);
}

function post(route, body) {
  var c = seam();
  return fetch(routeUrl(route), {
    method: "POST",
    headers: { "content-type": "application/json", "x-wb-exec": c.token },
    body: JSON.stringify(body || {})
  });
}

// ── dock.creds — keychain-backed, per-(user, provider) (user fixed by the host grant) ───────────

var creds = {
  // Returns the opaque blob string, or null when none stored yet (first sign-in).
  get: function (provider) {
    return post("creds/get", { provider: provider }).then(function (res) {
      if (!res.ok) throw new Error("creds.get denied (" + res.status + ")");
      return res.json();
    }).then(function (j) { return j && j.found ? j.blob : null; });
  },
  // Stores the opaque blob verbatim (the harness's own ~/.claude/.credentials.json-style bundle).
  put: function (provider, blob) {
    return post("creds/put", { provider: provider, blob: String(blob) }).then(function (res) {
      if (!res.ok) throw new Error("creds.put denied (" + res.status + ")");
      return res.json();
    }).then(function (j) { return !!(j && j.ok); });
  }
};

// ── dock.oauth.loopback — browser-open + loopback callback, PKCE-less (host returns only the code) ──

var oauth = {
  // params: { authorizeBase, codeChallenge, clientId?, scope?, state? }. The harness already made the
  // verifier+challenge in WebCrypto; we pass ONLY the challenge. Resolves to { code, redirectUri }; the
  // harness then exchanges code+verifier at the provider's token endpoint over its OWN fetch (NetGuard).
  loopback: function (params) {
    params = params || {};
    return post("oauth/loopback", {
      authorize_base: params.authorizeBase || params.authorize_base,
      code_challenge: params.codeChallenge || params.code_challenge,
      client_id: params.clientId || params.client_id,
      scope: params.scope,
      state: params.state
    }).then(function (res) {
      if (res.status === 503) throw new Error("oauth.loopback: desktop-only (no local browser here)");
      if (!res.ok) throw new Error("oauth.loopback failed (" + res.status + ")");
      return res.json();
    }).then(function (j) { return { code: j.code, redirectUri: j.redirect_uri }; });
  }
};

// ── PKCE helper (in-harness, WebCrypto) — verifier + S256 challenge; verifier never leaves the guest ──
//
// EMPIRICAL (the map §1): crypto.subtle.digest is present on StarlingMonkey, and crypto.getRandomValues +
// base64url cover the rest of RFC-7636. The host op takes only `challenge`.
function b64url(bytes) {
  var bin = "";
  var arr = new Uint8Array(bytes);
  for (var i = 0; i < arr.length; i++) bin += String.fromCharCode(arr[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pkce() {
  var raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  var verifier = b64url(raw);
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)).then(function (digest) {
    return { verifier: verifier, challenge: b64url(digest) };
  });
}

var dock = { creds: creds, oauth: oauth, pkce: pkce };

// Also expose on globalThis so a harness that doesn't `require` can reach it (Claude Code reads a global).
if (typeof globalThis !== "undefined") globalThis.dock = globalThis.dock || dock;

module.exports = dock;
