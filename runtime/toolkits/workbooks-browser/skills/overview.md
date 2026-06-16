# workbooks-browser — overview

# How to invoke (read this first)

  Every command below is a BUILT-IN `work` verb — run it DIRECTLY through your `work`
  tool (args="app status", args="model get"). Do NOT wrap them in `work toolkit
  run …` (that's only for compiled command-toolkits, and is refused here).
  `work toolkit show …` just READS these skills.

# What this toolkit is

  You are an agent in a Workbooks runtime that a desktop shell (the "browser")
  is connected to. This toolkit drives that shell — the live UI the user sees —
  plus a few host capabilities, all through `work` commands. There is no separate
  API to manage; you speak the same `desktop:control` channel the app listens on.

# The golden rule: probe first

  A shell may or may not be connected. Check before assuming:

  : work app status        ;; "1 desktop shell connected" | "(no desktop shell connected)"

  Every drive command is a SAFE NO-OP when nothing is connected — it says so
  rather than erroring — so you can act optimistically and report honestly.

# Command quick-reference (the live verbs)

  Tabs (paths are WORKSPACE-RELATIVE, never absolute OS paths):
  : work app open-tab  <path>
  : work app focus-tab <path>
  : work app close-tab <path>

  App surfaces:
  : work app theme     <id>            ;; switch to an EXISTING theme id (can't author new ones yet)
  : work app bookmark  <path> [title]  ;; add a bookmark
  : work app workspace <name> [icon]   ;; create a workspace (icon = an emoji)

  Ask the user for a secret (pops a modal, blocks until answered):
  : work env request   <NAME> [reason] ;; you NEVER see the raw value — stored by reference

  Models — for ANY question about which model to use, inspect/discover with THESE
  commands (they read the live OpenRouter catalog), never a web search:
  : work model get                     ;; the concrete model id you run on right now
  : work models list   [query]         ;; query matches id/name/modality, e.g. `work models list image`
  : work model set     <id>            ;; switch the model you run on (this session)
  To recommend whether to SWITCH, do both: `work model get` to read what you run on
  now, THEN `work models list <need>` to see candidates — compare, then advise.
  You do NOT already know your current model id — it is NOT in this prompt. The
  only way to state it is to actually run `work model get`; don't guess or skip it.

  Find content in the user's own workbooks (recall before re-deriving):
  : work search <words>                  ;; hybrid search over their library → workbook/path :: headline + snippet
  : work search <words> --semantic|--literal|--workbook <id>
  : work library                         ;; list their workspaces + members
  "(no matches)" means nothing matched — say so, don't invent a result.

  Variables — a per-tenant store for config + secrets (secrets by reference):
  : work var set <KEY> <VALUE>           ;; plain config value
  : work var set <KEY> <VALUE> --secret  ;; a secret — stored by reference, you can't read it back
  : work var get <KEY>                   ;; plain value (secrets come back REDACTED)
  : work var list                        ;; keys + plain/secret, never secret values
  : work var ref "{{secret:KEY}}"        ;; reference a secret in a template; the host expands it

# Honesty

  Only promise what's listed above. Theme AUTHORING and workspace SWITCHING are
  not wired yet — say so rather than inventing a command. Read a skill for detail:
  `work toolkit show workbooks-browser <skill>` (tab-control, app-control,
  key-prompt, models).
