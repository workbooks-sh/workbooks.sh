# Deep-research AGENT capacity on a 1GB host — the north-star measurement.
#
# After the Floki cheap-read default, an agent's local RAM is: (a) its BEAM process + accumulated
# research context (grows with pages read, like a real agent's message history), (b) transient Floki
# parse buffers (GC'd), (c) the occasional Blitz render — but renders are GATED at a fixed slot count,
# so they're a CONSTANT slice, not a per-agent cost. The LLM is remote (zero local RAM). So capacity
# extrapolates cleanly: agents_per_1GB ≈ (1024 - base - render_budget) / marginal_RSS_per_agent.
#
# Each agent runs a realistic browse-heavy loop for DURATION sec: read a DISTINCT page via the
# default no-wasm path (Nexus.Browse.read), accumulate title + citations + a markdown excerpt into a
# bounded context buffer (a real agent's working memory), and every RENDER_EVERY-th page escalate to
# a gated Blitz render (the "needs layout" minority). We ramp concurrency and measure marginal RSS.
#
#   cd nexus && WAVES=20,50,100 DURATION=12 mix run scripts/agent_capacity_1gb.exs

defmodule AgentCapacity1GB do
  @duration String.to_integer(System.get_env("DURATION", "12"))
  @render_every String.to_integer(System.get_env("RENDER_EVERY", "8"))
  @ctx_cap 80_000   # per-agent context buffer cap (chars) — a realistic research working set

  @slugs ~w[
    WebAssembly Erlang Elixir_(programming_language) Rust_(programming_language) LLVM Compiler
    Garbage_collection_(computer_science) Concurrency_(computer_science) Actor_model Operating_system
    Linux_kernel Virtual_memory Cgroups Container_(virtualization) Docker_(software) KVM Hypervisor
    QEMU Capability-based_security WASI Cloudflare Content_delivery_network HTTP QUIC Transport_Layer_Security
    Public-key_cryptography SHA-2 Merkle_tree Distributed_hash_table Raft_(algorithm) Paxos_(computer_science)
    PostgreSQL SQLite Vector_database Nearest_neighbor_search Transformer_(deep_learning_architecture)
    Large_language_model Attention_(machine_learning) Reinforcement_learning Gradient_descent Backpropagation
    Convolutional_neural_network GPU CUDA Floating-point_arithmetic IEEE_754 Unicode UTF-8 Regular_expression
    Finite-state_machine Turing_machine Lambda_calculus Type_system Functional_programming B-tree Hash_table
    Bloom_filter Trie Skip_list Quicksort Graph_(abstract_data_type) Dynamic_programming Cache_(computing)
    CPU_cache Memory_hierarchy Branch_predictor Out-of-order_execution Speculative_execution Domain_Name_System
    Border_Gateway_Protocol IPv6 Anycast Load_balancing_(computing) Reverse_proxy WebSocket GraphQL
    Protocol_Buffers Apache_Kafka Event_sourcing Eventual_consistency CAP_theorem Consensus_(computer_science)
  ]

  def url(i), do: "https://en.wikipedia.org/wiki/" <> Enum.at(@slugs, rem(i, length(@slugs)))

  # one research agent: browse distinct pages, accumulate a bounded research context, occasionally
  # render. Returns {pages_read, renders, ctx_bytes, citations}.
  def agent(aid, deadline) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while(%{pages: 0, renders: 0, ctx: "", cites: 0}, fn it, acc ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, acc}
      else
        u = url(aid * 7919 + it)
        render? = rem(it, @render_every) == @render_every - 1

        case Nexus.Browse.read(u, if(render?, do: [render: true], else: [])) do
          {:ok, r} ->
            # accumulate research context like a real agent's message history (bounded)
            note = "## #{r.title}\n#{String.slice(r.markdown, 0, 1500)}\n"
            ctx = String.slice(acc.ctx <> note, 0, @ctx_cap)
            {:cont, %{acc | pages: acc.pages + 1, ctx: ctx, cites: acc.cites + length(r.links),
                      renders: acc.renders + if(r.via == :blitz, do: 1, else: 0)}}

          _ ->
            {:cont, acc}
        end
      end
    end)
  end

  def total_rss_mb do
    {out, _} = System.cmd("sh", ["-c", "ps -axo rss=,comm= | grep -E 'beam.smp|[w]asmtime'"])
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn l -> l |> String.trim() |> String.split() |> hd() |> String.to_integer() end)
    |> Enum.sum()
    |> div(1024)
  end

  def wave(n) do
    IO.puts("\n━━━ #{n} concurrent research agents (#{@duration}s, render every #{@render_every}th page) ━━━")
    deadline = System.monotonic_time(:millisecond) + @duration * 1000

    parent = self()
    sampler = spawn(fn -> sample(deadline, parent, 0) end)

    results =
      1..n
      |> Enum.map(fn aid -> Task.async(fn -> agent(aid, deadline) end) end)
      |> Task.await_many(:infinity)

    peak = receive do
      {:peak, mb} -> mb
    after
      3000 -> total_rss_mb()
    end
    Process.exit(sampler, :kill)

    pages = Enum.sum(Enum.map(results, & &1.pages))
    renders = Enum.sum(Enum.map(results, & &1.renders))
    ctx = Enum.sum(Enum.map(results, &byte_size(&1.ctx)))
    cites = Enum.sum(Enum.map(results, & &1.cites))
    gate = Nexus.Wasm.Gate.stats(:render)

    IO.puts("  peak RSS: #{peak} MB   pages: #{pages}  renders: #{renders}  citations: #{cites}")
    IO.puts("  agent ctx held: #{div(ctx, 1024)} KB total (#{div(ctx, max(n, 1)) |> div(1024)} KB/agent)  render-gate: #{inspect(gate)}")
    %{n: n, peak_mb: peak, pages: pages, renders: renders}
  end

  defp sample(deadline, parent, peak) do
    if System.monotonic_time(:millisecond) >= deadline do
      send(parent, {:peak, peak})
    else
      mb = total_rss_mb()
      Process.sleep(150)
      sample(deadline, parent, max(peak, mb))
    end
  end

  def run do
    waves = System.get_env("WAVES", "20,50,100") |> String.split(",") |> Enum.map(&String.to_integer/1)
    base = total_rss_mb()
    IO.puts("Deep-research agent capacity → 1GB extrapolation")
    IO.puts("idle baseline RSS: #{base} MB   render lane: #{inspect(Nexus.Wasm.Gate.stats(:render))}")

    summary = Enum.map(waves, &wave/1)

    IO.puts("\n══════════ CAPACITY (extrapolate to 1024 MB) ══════════")
    IO.puts("agents | peakRSS | pages | renders | MB/agent")
    Enum.each(summary, fn s ->
      :io.format("~6w | ~6w MB | ~5w | ~7w | ~6.2f~n", [s.n, s.peak_mb, s.pages, s.renders, (s.peak_mb - base) / max(s.n, 1)])
    end)

    # marginal MB/agent from the two widest waves → agents that fit in 1GB
    if length(summary) >= 2 do
      lo = hd(summary); hi = List.last(summary)
      dpeak = hi.peak_mb - lo.peak_mb
      dn = hi.n - lo.n

      if dn > 0 and dpeak > 0 do
        per = dpeak / dn
        ceil = round((1024 - base) / per)
        IO.puts("\nmarginal: ~#{Float.round(per, 2)} MB per concurrent agent (idle base #{base} MB)")
        IO.puts("→ a 1GB Fly machine holds ≈ #{ceil} concurrent deep-research agents")
        IO.puts("  (renders are gated at #{Nexus.Wasm.Gate.stats(:render).limit} slots — a FIXED slice, not per-agent;")
        IO.puts("   the LLM is remote, so it adds latency but ~0 local RAM)")
      else
        IO.puts("\nmarginal RSS below noise floor at this scale — agents are BEAM-cheap; push WAVES higher.")
      end
    end
  end
end

AgentCapacity1GB.run()
