"""Last-resort: LLM-extract product cards from listing pages.

The agent walks the homepage + likely category links (heuristic), then asks
the LLM to extract structured product cards from rendered HTML."""
# TODO: implement crawl(domain, llm_fn) -> AsyncIterator[Product]
