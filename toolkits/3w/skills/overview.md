# 3w — overview (the verb map, the cost model, what's live)
0.1.0
Use on first contact with 3w. The verb surface, the $0 cost model, the Google exclusion, and which verbs are live vs landing with later phases.

# When to use this
NETWORK: no
DESTRUCTIVE: no
COST: free

  Read this first when you haven't used `3w` in this session. It orients you to
  the verbs and the rules that keep it cheap and unblocked.
  NOT for: the actual recipes — those are the per-verb skills linked below.

# What 3w is

  A local-first deep-research browser baked into the sandbox. No API keys, no
  per-call cost: search is native multi-engine, reads impersonate Chrome, JS
  rendering is a local headless browser (Lightpanda). Egress is from *this*
  sandbox's IP. The endgame is compiling a research run into a portable
  *workbook context repository* (raw searchable index + media + agent-authored
  org analysis) — those verbs come online across bd epic wb-ebwt.

# The verb surface

  | Verb            | Status | What                                                    |
  |-----------------|--------|---------------------------------------------------------|
  | `3w search`     | live   | keyless multi-engine search ([search](search.md)) |
  | `3w read`       | live   | URL → clean markdown, JS-aware ([read-extract](read-extract.md)) |
  | `3w browse`     | soon   | interactive snapshot/act (agent-browser + Lightpanda)   |
  | `3w crawl`      | soon   | frontier crawl + page-template extraction               |
  | `3w harvest`    | soon   | media/SVG/font + component catalog                      |
  | `3w har`        | soon   | capture network session → mine hidden JSON endpoints    |
  | `3w repo`       | soon   | assemble the workbook context repository (`wb build`)   |
  | `3w doctor`     | soon   | run the troubleshooting checks                          |

# The rules that keep it free + unblocked

  1. *No Google.* The native pool is ddg+bing+brave+mojeek. Google's wall is
     JS/behavioral and unscrapeable cheaply — never try to force it; widen
     engines or use a paid SERP backend if a deploy truly needs it.
  2. *Search before read.* Don't guess URLs; `search` is the on-ramp.
  3. *Let read pick its tier.* Cheap Http fetch by default; render only when a
     page needs JS. Don't blanket `--render`.
  4. *Cross-engine consensus = trust.* Prefer results several engines agree on.

# See also

  - [search](search.md) — find pages by query
  - [read-extract](read-extract.md) — read a URL as markdown
  - [troubleshoot](troubleshoot.md) — when search/read comes back empty or walled
