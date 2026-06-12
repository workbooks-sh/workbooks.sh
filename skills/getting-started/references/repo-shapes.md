# Repo shapes — detection table

Classify before acting. The shape decides your task ledger and which sibling
skill you hand off to.

| Signal present | Shape | Task ledger | Typical work |
|---|---|---|---|
| `runtime/` + Elixir `mix.exs` + `runtime/host/` | **Platform repo** | `bd` (beads) | engine, CLI, toolkits, desktop |
| `toolkits/` but no `runtime/` | **Consumer project** | `bd` if tracked, else just act | build workbooks/toolkits on the platform |
| `app/` self-building site + an org `BOARD` / `:TASK:` headings | **Tenant artifact** | in-repo org board | the site's own agent loop |
| only `skills/` + `.html` artifacts | **Workbook project** | direct / follow-ups | author/edit single-file workbooks |

## Probes

```sh
ls skills toolkits runtime 2>/dev/null
test -f runtime/mix.exs && echo "platform: Elixir runtime present"
test -d runtime/host && echo "platform: host engine present"
ls **/BOARD* 2>/dev/null && echo "tenant: org board present"
command -v bd >/dev/null && echo "bd available (platform ledger)"
```

## Why it matters

- **Two ledgers, never crossed.** Platform/engine work → `bd` (local Dolt,
  NEVER committed to git). Tenant artifact work → the in-repo org board
  (`:TASK:`/state front-matter parsed by the workflow engine). See the
  `working-with-tasks` skill for the full distinction.
- **HOST vs LOADED.** Platform repos contain HOST engine code (changes only via
  a new runtime image). Consumer/tenant repos carry LOADED artifacts (hot-swap).
  Self-modifying agents edit LOADED, never HOST.
