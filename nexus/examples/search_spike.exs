# Live, keyless, all-in-one web-search spike for the nexus runtime.
#
#   mix run examples/search_spike.exs "BEAM concurrency"
#
# Runs the full pipeline against LIVE public APIs + keyless HTML engines, then a local semantic
# rerank — NO API keys, reliable from a datacenter IP:
#
#   1. Fan out the query to OPEN PUBLIC CORPORA (Wikipedia, Hacker News, OpenAlex, Internet Archive,
#      CommonCrawl) AND the keyless HTML metasearch engines (DuckDuckGo-HTML, Mojeek, Startpage),
#      concurrently, each via Nexus.Dock.fetch (SSRF-safe GET, curl-impersonate escalation), each with
#      a per-source timeout so one slow API can't stall results.
#   2. FUSE every source into ONE ranked list with reciprocal-rank fusion (Nexus.Browse.Search.Rank):
#      canonicalize-by-URL → dedupe → Σ weight·(1/position) + cross-engine agreement bonus.
#   3. RERANK with the nexus's own keyless embedding service (Nexus.Embed → Nexus.Browse.Search.
#      Semantic): blend RRF rank with cosine similarity of query vs each candidate's title+snippet.
#
# Embedding backend: the shipped default is Nexus.Embed.Hashed — a deterministic, dependency-free
# hashed character-trigram embedding (lexical/character overlap → cosine). The PIPELINE is live and
# correct end-to-end; swap in a real GGUF/Bumblebee semantic model at Nexus.Embed's documented
# model-swap point (set <work-deploy embed="bge-small"> + add the name→module mapping) with no other
# change to this pipeline.
#
# NEXT STEP (central shared index, not yet built): periodically embed a slice of a public corpus
# (e.g. Wikipedia) into pgvector for SHARED semantic recall — public data needs no per-tenant
# isolation, so it's one shared index the whole fleet queries. Sketched here, deferred.

query = case System.argv() do
  [q | _] -> q
  [] -> "BEAM concurrency"
end

IO.puts("\n\e[1mnexus keyless search spike\e[0m — query: \e[36m#{query}\e[0m\n")
IO.puts("fanning out: HTML engines (ddg/mojeek/startpage) + corpora (wikipedia/hackernews/openalex/archive/commoncrawl)\n")

t0 = System.monotonic_time(:millisecond)

{:ok, results} =
  Nexus.Browse.Search.Metasearch.search(query, limit: 10, semantic: true)

dt = System.monotonic_time(:millisecond) - t0

if results == [] do
  IO.puts("\e[33mno results — every source returned empty (datacenter block or transient). Re-run.\e[0m")
else
  results
  |> Enum.with_index(1)
  |> Enum.each(fn {r, i} ->
    engines = (r[:engines] || []) |> Enum.map_join(",", &to_string/1)
    score = r[:score] || 0.0
    sem = r[:semantic] || 0.0
    title = String.slice(r.title || "(untitled)", 0, 90)
    snippet = String.slice(r[:snippet] || "", 0, 110)

    IO.puts("\e[1m#{String.pad_leading(to_string(i), 2)}.\e[0m \e[1m#{title}\e[0m")
    IO.puts("    \e[34m#{r.url}\e[0m")
    IO.puts("    \e[2mscore=#{score}  semantic=#{sem}  sources=[#{engines}]\e[0m")
    if snippet != "", do: IO.puts("    \e[2m#{snippet}…\e[0m")
    IO.puts("")
  end)
end

IO.puts("\e[2m#{length(results)} results in #{dt}ms — keyless (no API key), fused + semantically reranked\e[0m\n")
