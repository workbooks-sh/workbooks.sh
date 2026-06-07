# Catalog-crawl diagnosis — correction (2026-06-05, wb-syjo)

An earlier finding claimed `brandnana catalog crawl` "exits 0 silently on the
409." That was WRONG — a probe artifact: I measured `$?` after `cmd | tail`, so I
read tail's exit code, not brandnana's.

## Verified facts (clean measurement, live new CLI built 07:02:46Z)

- Normal run: `crawl complete: 1365 products, 4872 images`, **exit 0**, all 1365
  in LOCAL sqlite. The crawl WORKS.
- Failure: the CLI **exits non-zero** — `emitError` calls `process.exit(1)`
  unconditionally; a failed/superseded crawl returned exit 1.

## True root of the agent's 14× spin

The first catalog crawl for a brand is slow (uncached, full site scrape). The
engine runs agent bash SYNCHRONOUSLY with a timeout; the slow first crawl's bash
was CUT. The crawl is an async Durable Object, so it kept running server-side.
The agent RE-RAN the verb → `409 crawl_in_progress` (exit 1) → the LLM retried,
14×. Not a silent failure — a retry-on-409 loop.

## Fixes (shipped + live)

1. CLI: on 409, `waitForCrawl` polls `/catalog/status/:domain` to completion and
   exits 0 with the finished counts (breaks the retry loop); fails loud on
   server-failure/timeout. (SDK gained `catalog.status`.)
2. `fm-harvest-retry-spin` failmode steers the agent off a stuck verb.

## Lesson

Adversarially verify exit codes WITHOUT a pipe (`cmd >f 2>&1; echo $?`), never
`cmd | tail; echo $?`. The pipe's last stage owns `$?`.
