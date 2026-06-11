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
| [`sources/`](sources/) | raw inputs, untouched. One dir per session (transcripts word-for-word, per-word timing JSON). More media types over time. |
| [`audits/`](audits/) | working documents derived from sources — claims ledgers, argument maps, open questions. |

## Sources so far

| source | what | derived |
|---|---|---|
| [`2026-06-10-spoken-thesis/`](sources/2026-06-10-spoken-thesis/) | 91-min unscripted voice memo on the whole ecosystem (workbook / runtime / toolkits / autopoet), ElevenLabs scribe_v1, 8,578 words | [`audits/spoken-thesis.org`](audits/spoken-thesis.org) |

## The pipeline

recording → speech-to-text → verbatim source → claims extraction →
evidence-checked audit → backlog. Each step is agent-runnable; the method is
a candidate toolkit (audio in, claims ledger out).
