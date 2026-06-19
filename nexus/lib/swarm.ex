defmodule Nexus.Swarm do
  @moduledoc """
  A research **swarm** — a ramping fleet of real search+scrape agents on one nexus, each streaming its
  live state. The showcase for "how many concurrent agents fit on a single nexus": a query fans out
  into a tree of agents that search (keyless metasearch) and read (streaming `Extract`), spawning
  child agents for the links/subtopics they find until the fleet hits a max-agent budget. Every state
  transition is pushed to `emit` so a single-viewport UI can render hundreds of live agent windows.

  `run(query, max, emit)` blocks until the fleet drains. `emit.(event)` is called with maps:

    * `%{type: "fleet", query, max}`                                  — fleet started
    * `%{type: "spawn", id, parent, depth, query}`                    — a new agent (→ a new tile)
    * `%{type: "state", id, status, action, url, findings}`          — an agent changed state
    * `%{type: "done", spawned}`                                      — fleet drained

  `status` ∈ `searching | reading | thinking | spawning | done`. The agents do REAL work — the
  concurrency, the network, and the BEAM process count are genuine; only the fan-out shape is the
  demo. Tune with opts: `:fanout` (children per agent, default 3), `:depth` (max tree depth,
  default 4), `:reads` (pages each agent scrapes, default 2).
  """

  @doc "Run a research swarm for `query`, capped at `max` agents, streaming state to `emit`."
  def run(query, max, emit, opts \\ []) when is_function(emit, 1) do
    max = max |> max(1) |> min(1000)
    fanout = Keyword.get(opts, :fanout, 3)
    depth = Keyword.get(opts, :depth, 4)
    reads = Keyword.get(opts, :reads, 2)

    # shared spawned-counter (atomics) — every agent bumps it; children stop when the budget is hit.
    counter = :counters.new(1, [:atomics])
    :counters.add(counter, 1, 1)

    emit.(%{type: "fleet", query: query, max: max})

    ctx = %{counter: counter, budget: max, fanout: fanout, depth: depth, reads: reads, emit: emit}
    agent("a1", nil, query, 0, ctx)

    emit.(%{type: "done", spawned: :counters.get(counter, 1)})
  end

  # one agent: announce → search → read a few → spawn children for fresh links → wait → done.
  defp agent(id, parent, query, depth, ctx) do
    emit = ctx.emit
    emit.(%{type: "spawn", id: id, parent: parent, depth: depth, query: query})

    # SEARCH (real, keyless metasearch)
    emit.(%{type: "state", id: id, status: "searching", action: query})
    results = search(query)
    emit.(%{type: "state", id: id, status: "thinking", action: "ranked #{length(results)} sources", findings: length(results)})

    # READ a few (real streaming Extract)
    results
    |> Enum.take(ctx.reads)
    |> Enum.each(fn %{title: t, url: u} ->
      emit.(%{type: "state", id: id, status: "reading", action: clean(t), url: u})
      _ = read(u)
    end)

    # SPAWN children for the next sources / subtopics, while the global budget holds.
    children =
      if depth < ctx.depth do
        results
        |> Enum.drop(ctx.reads)
        |> Enum.take(ctx.fanout)
        |> Enum.flat_map(fn %{title: t, url: u} ->
          if claim(ctx) do
            cid = id <> "." <> Integer.to_string(:erlang.unique_integer([:positive, :monotonic]))
            ct = clean(t)
            emit.(%{type: "state", id: id, status: "spawning", action: "→ " <> ct})
            [Task.async(fn -> agent(cid, id, ct, depth + 1, ctx) end)]
          else
            []
          end
        end)
      else
        []
      end

    Task.await_many(children, :infinity)
    emit.(%{type: "state", id: id, status: "done"})
  end

  # atomically claim a slot in the agent budget; false when the fleet is full.
  defp claim(ctx) do
    if :counters.get(ctx.counter, 1) < ctx.budget do
      :counters.add(ctx.counter, 1, 1)
      true
    else
      false
    end
  end

  # Clean a search-result title for display/subquery: drop embedded CSS/markup junk, collapse
  # whitespace, truncate. (Some engines leak styling into result titles.)
  defp clean(title) when is_binary(title) do
    title
    |> String.replace(~r/\.css-[^{]*\{[^}]*\}/, "")
    |> String.replace(~r/@media[^{]*\{[^}]*\}/, "")
    |> String.replace(~r/\{[^}]*\}/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp clean(_), do: ""

  defp search(query) do
    case Nexus.Browse.search(query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  rescue
    _ -> []
  end

  defp read(url) do
    case Nexus.Browse.read(url) do
      {:ok, r} -> r
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
