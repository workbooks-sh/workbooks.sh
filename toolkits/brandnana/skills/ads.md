# brandnana — ads

# When to use this

Find what a brand is actually saying in-market — its live ad creatives across
Meta / Google / TikTok, or a broad creative search. The raw signal for voice,
offers, and positioning evidence.

# Common verbs

```bash
brandnana ads search <query>                 # broad creative search (default: all sources)
brandnana ads search <query> --source meta   # exa | meta | tiktok | google | all
brandnana ads search <query> --brand <domain> --limit 20
brandnana ads sync --source meta --ad-account-id act_1234 --limit 50
```

`ads search` is the discovery verb — use it first. `ads sync` pulls a specific
Meta ad account into the local sqlite (`--db`) tagged to a `--brand-id`; only the
`meta` source is implemented for sync today. `--no-save` skips the local write.

# What "good" looks like

- Scope searches with `--brand <domain>` so results are the brand's own library,
  not generic matches.
- Use the creatives as evidence (hooks, offers, recurring claims) — quote them in
  the workbook's argument, don't just list them.

# Common pitfalls

- Treating `ads sync` as a search — it targets one known ad account, not discovery.
- Over-broad `search` queries; tighten with `--brand` and `--source`.

# See also

- `overview`, `social` (organic voice), `brief` (turns signal into a brief).
