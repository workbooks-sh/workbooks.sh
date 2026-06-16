# workbooks-browser — variables

# Store config + secrets for the user (per-tenant, secrets by reference)

  Each tenant has a private key-value store for config values and secrets. Use it
  to remember settings the user gives you (an API base URL, a project id) and to
  hold secrets WITHOUT ever seeing them.

  : wb var set <KEY> <VALUE>            ;; a plain config value
  : wb var set <KEY> <VALUE> --secret   ;; a SECRET — stored by reference
  : wb var get <KEY>                    ;; read a plain value (secrets come back REDACTED)
  : wb var list                         ;; list keys (plain vs secret), never secret values
  : wb var ref "<template>"             ;; expand {{var:KEY}} / {{secret:KEY}} in a string

# Secrets by reference — the rule

  A value set with `--secret` is stored by reference: `wb var get` returns a
  redacted placeholder, NOT the value (e.g. "<secret: 13 bytes — ref it with
  {{secret:TOKEN}}, cannot read>"). You never see it. To USE a secret, don't try
  to read it — reference it in a template and let the host expand it at the edge:

  : wb var set OPENAI_KEY sk-... --secret
  : wb var ref "Authorization: Bearer {{secret:OPENAI_KEY}}"   ;; host injects it; you never hold it

  This is the same secrets-by-reference guarantee as `wb env request` (the modal
  path) — see the key-prompt skill. Set-by-reference vs ask-the-user are the two
  ways a secret enters the store; both keep the raw value out of your context.

# Honesty + scope

  - The store is PER-TENANT — what you set is the user's, not shared.
  - NEVER claim to know a secret's value; you genuinely can't read it back.
  - Plain vars ARE readable (they're config, not secrets) — use `--secret` only
    for things that must stay hidden (keys, tokens, passwords).
