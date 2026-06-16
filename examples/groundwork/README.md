# groundwork — zero-to-one ideation, on workbooks

The system for understanding our own product by listening to ourselves talk
about it. Raw founder material goes in — voice memos, videos, pitch run-ups,
whatever gets recorded — and comes out as auditable working documents:
claims checked against the shipped repo, positioning, audience, competitors,
and a backlog driven by the gap between what was said and what is true.

This is itself a workbooks showcase: the method is the product demo. Ideation
isn't a transcript rotting in a notes app — it's a living org document where
every load-bearing claim carries an honesty status (`KEPT / PARTIAL / UNKEPT /
FUTURE / RETRACTED`) and a pointer to evidence.

## Layout

| dir | what |
|---|---|
| [`sources/`](sources/) | raw inputs, untouched. One dir per session (transcripts word-for-word, per-word timing JSON), plus `captures/` (distilled thoughts the groundskeeper saves mid-conversation) and archived call transcripts. |
| [`audits/`](audits/) | working documents derived from sources — claims ledgers, argument maps, open questions. |
| [`design/`](design/) | the groundskeeper voice agent — design + go-live runbook (epic wb-3ojf). |
| [`agent/`](agent/) | the groundskeeper's def (persona in the `<work-system>` element, the provisioning source of truth). |
| [`workflows/`](workflows/) | TODO-outline workflows authored by the dispatch lane's author model (Mercury 2). They persist — a growing library. |
| [`rehearsals/`](rehearsals/) | self-demo transcripts: the persona + tools driven through the real bridge with no human and no ElevenLabs. |
| [`TASKS.md`](TASKS.md) | the dispatched-task ledger, generated from the runtime — never hand-edited. |
| [`brand/`](brand/) | the mascot. |

## Sources so far

| source | what | derived |
|---|---|---|
| [`2026-06-10-spoken-thesis/`](sources/2026-06-10-spoken-thesis/) | 91-min unscripted voice memo on the whole ecosystem (workbook / runtime / toolkits / autopoet), ElevenLabs scribe_v1, 8,578 words | [`audits/spoken-thesis.md`](audits/spoken-thesis.md) |

## The pipeline

recording → speech-to-text → verbatim source → claims extraction →
evidence-checked audit → backlog. Each step is agent-runnable; the method is
a candidate toolkit (audio in, claims ledger out).
