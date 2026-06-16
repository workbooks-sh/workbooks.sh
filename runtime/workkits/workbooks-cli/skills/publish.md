# workbooks-cli — publish

# Render a Workbook → a live URL

  `work publish` turns a Workbook (`.org`) into self-contained HTML and ships it.
  Non-interactive; add `--json` for machine output (exit 0 ok / non-zero fail).

# The flow

  : work publish init               ;; scaffold ./publish.org
  ;; → user edits publish.org (target, project, optional domain/title)
  : work publish validate           ;; coherence-check it — no render, no deploy
  : work publish apply <file.org>   ;; render + ship → prints the live URL
  ;; (workbook defaults to ./workbook.org; config defaults to ./publish.org)

# Multi-page sites

  : work publish site [<dir>]       ;; render a multi-page site from site.org → deploy

# What publish.org declares

  | Key             | Meaning                                                  |
  |-----------------|----------------------------------------------------------|
  | PUBLISH_TARGET  | cloudflare-pages \vert gh-pages \vert self-hosted        |
  | PUBLISH_PROJECT | CF Pages project name / GitHub repo (org/name) / runtime URL |
  | PUBLISH_DOMAIN  | optional custom domain (used only for the printed URL)   |
  | PUBLISH_TITLE   | page <title> (falls back to PUBLISH_PROJECT)             |
  | PUBLISH_OUTPUT  | where to write the HTML (default .publish_out/index.html)|

# Honesty

  - `apply` is the only verb that deploys — `validate` never does. Run `validate`
    first and report it.
  - The printed URL is the real, live result — quote it back; don't fabricate one.
  - If the target needs a credential the user hasn't provided, say which one and
    stop (you can request it with `work env request <NAME>` if the browser toolkit
    is also available).
