# byod

Turn a forged workbook into a real, multi-tenant app with a live database and the developer's own auth — no agent engine required. The pattern: a workbook's single-file frontend talks to a live Postgres (Crunchy / Railway / RDS) or Cloudflare D1 through a secure data backend, with BetterAuth for sign-in, sessions, organizations, and API keys — pointed at via a PUBLIC connection descriptor injected into the `.html` (never DB credentials, never server code).

## When to reach for it

Reach for `byod` when a workbook has graduated from a demo to something real users sign into and write to — and you want a live backend on your own infrastructure with your own auth, not a hosted engine.

## Example

```js
// The descriptor injected into the page points at your backend:
const wb = JSON.parse(document.getElementById("workbook-backend").textContent);
// sign in (bearer), then run NAMED, tenant-scoped queries — no raw SQL, no DB creds in the browser
const r = await fetch(`${wb.auth.baseURL}/sign-in/email`, { method:"POST", /* … */ });
const token = r.headers.get("set-auth-token");
```

## What it grants

- The architecture + frontend wiring for a live DB backend (Postgres or Cloudflare D1) the workbook talks to over `fetch` — the workbook never holds DB creds.
- The developer's own auth: BetterAuth sessions, multi-tenant organizations, and API keys; server-verified tenant isolation; named-query-only access.

## Maturity

Experimental. The turnkey provisioning (`wb forge app deploy`) and its bundled gateway were removed 2026-06-09 and are **not currently available** (restore-or-drop tracked in `wb-dtd0.1`); the skill gives the architecture + frontend wiring and points at the real provider tools (`cloudflare` / `railway` / `wrangler` toolkits + BetterAuth) to stand up the backend yourself.
