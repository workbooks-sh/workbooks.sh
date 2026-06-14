# byod

Turn a forged workbook into a real, multi-tenant app with a live database and the developer's own auth — no agent engine required. `byod` wraps `wb forge app` to connect a workbook's single-file frontend to a live Postgres (Crunchy / Railway / RDS) through a secure data gateway, with BetterAuth for sign-in, sessions, organizations, and API keys.

## When to reach for it

Reach for `byod` when a workbook has graduated from a demo to something real users sign into and write to — and you want a live backend on your own infrastructure with your own auth, not a hosted engine.

## Example

```
wb forge app   # connect the forged workbook to a live Postgres + BetterAuth
# the .html frontend gets a PUBLIC connection descriptor injected —
# never DB credentials, never server code
```

## What it grants

- A live Postgres backend behind a secure data gateway (the workbook never holds DB creds).
- The developer's own auth: BetterAuth sessions, multi-tenant organizations, and API keys.
- A deployable gateway that ships separately from the `.html` and is pointed at via a public connection descriptor.

## Maturity

Experimental. Requires `wb`, Node 20+, and Railway 3+ to deploy the gateway. The sibling toolkit `cloudflare` does the same on a single Cloudflare account if you'd rather have one provider and one bill.
