# Browser-system memory saturation — REAL nexus runtime, 1GB ceiling.
#
# The agent itself is a cheap BEAM process; the RAM cost is the wasmtime SUBPROCESS each
# render/exec spawns (Blitz: render_text.wasm + DOM/layout heap). So the OOM ceiling is set by
# PEAK SIMULTANEOUS wasmtime processes, not agent count. This ramps render-active concurrency,
# samples peak RSS of (beam.smp + all wasmtime children), and finds where it crosses 1GB.
#
# Each worker loops for DURATION sec, rendering a DISTINCT page each iteration (no cache sharing),
# pulling text + counting citations — "normal research" load. We measure:
#   * peak RSS (MB) of the whole runtime at each concurrency level
#   * ok / unreachable (fetch fail) / render-fail counts  ← "pages we couldn't reach"
#   * derived: MB per concurrent wasm process, and agents-per-1GB
#
#   cd nexus && mix run scripts/browser_saturation.exs
#   WAVES=8,16,32,64,128 DURATION=12 CAP_MB=1024 mix run scripts/browser_saturation.exs

defmodule BrowserSaturation do
  @cap_mb String.to_integer(System.get_env("CAP_MB", "1024"))
  @duration String.to_integer(System.get_env("DURATION", "12"))

  # Distinct, real, citation-rich pages. Cycled with a per-worker+iteration offset so no two
  # concurrent renders hit the same URL (no cache collisions — genuinely different research).
  @slugs ~w[
    WebAssembly Erlang Elixir_(programming_language) BEAM_(Erlang_virtual_machine) Rust_(programming_language)
    LLVM Compiler Just-in-time_compilation Garbage_collection_(computer_science) Concurrency_(computer_science)
    Actor_model Operating_system Linux_kernel Virtual_memory Cgroups Container_(virtualization) Docker_(software)
    KVM Hypervisor MicroVM QEMU Sandbox_(computer_security) Capability-based_security WASI Cloudflare
    Content_delivery_network HTTP HTTP/2 QUIC Transport_Layer_Security Public-key_cryptography SHA-2 Merkle_tree
    Content-addressable_storage Distributed_hash_table Raft_(algorithm) Paxos_(computer_science) PostgreSQL SQLite
    Vector_database Nearest_neighbor_search Locality-sensitive_hashing Transformer_(deep_learning_architecture)
    Large_language_model Attention_(machine_learning) Tokenization_(lexical_analysis) Reinforcement_learning
    Gradient_descent Backpropagation Convolutional_neural_network Recurrent_neural_network GPU CUDA
    Floating-point_arithmetic IEEE_754 Unicode UTF-8 Regular_expression Finite-state_machine Turing_machine
    Lambda_calculus Type_system Hindley%E2%80%93Milner_type_system Functional_programming Immutable_object
    Persistent_data_structure B-tree Hash_table Bloom_filter Trie Skip_list Red%E2%80%93black_tree Quicksort
    Dijkstra%27s_algorithm Graph_(abstract_data_type) Topological_sorting Dynamic_programming Cache_(computing)
    CPU_cache Memory_hierarchy Branch_predictor Out-of-order_execution Speculative_execution Spectre_(security_vulnerability)
    Domain_Name_System Border_Gateway_Protocol IPv6 Anycast Load_balancing_(computing) Reverse_proxy WebSocket
    Server-sent_events Representational_state_transfer GraphQL Protocol_Buffers Apache_Kafka Event_sourcing
    Command_query_responsibility_segregation Eventual_consistency CAP_theorem Consensus_(computer_science)
  ]

  def url(i), do: "https://en.wikipedia.org/wiki/" <> Enum.at(@slugs, rem(i, length(@slugs)))

  # peak RSS (MB) of beam.smp + every wasmtime process, right now.
  def rss_mb do
    {out, _} = System.cmd("sh", ["-c", "ps -axo rss=,comm= | grep -E 'beam.smp|wasmtime' | grep -v grep"])
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.trim() |> String.split() |> hd() |> String.to_integer() end)
    |> Enum.sum()
    |> Kernel./(1024)
    |> Float.round(1)
  end

  def wasm_count do
    {out, _} = System.cmd("sh", ["-c", "ps -axo comm= | grep -c '[w]asmtime' || true"])
    case Integer.parse(String.trim(out)) do
      {n, _} -> n
      _ -> 0
    end
  end

  # one worker: render distinct pages back-to-back until the deadline. Returns counters.
  def worker(wid, deadline) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while(%{ok: 0, unreachable: 0, render_fail: 0, citations: 0}, fn it, acc ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, acc}
      else
        u = url(wid * 7919 + it)            # 7919 prime → worker streams diverge, stay distinct
        case Nexus.Browse.fetch(u) do
          {:error, _} ->
            {:cont, %{acc | unreachable: acc.unreachable + 1}}
          {:ok, html} ->
            case Nexus.Browse.Blitz.render_html(html, u, engine: :auto) do
              {:ok, text} ->
                c = Regex.scan(~r/https?:\/\/[^\s)\]]+/, text) |> length()
                {:cont, %{acc | ok: acc.ok + 1, citations: acc.citations + c}}
              {:error, _} ->
                {:cont, %{acc | render_fail: acc.render_fail + 1}}
            end
        end
      end
    end)
  end

  def wave(n) do
    IO.puts("\n━━━ #{n} concurrent render-active agents (#{@duration}s) ━━━")
    deadline = System.monotonic_time(:millisecond) + @duration * 1000

    # peak-RSS sampler: poll every 200ms during the wave
    parent = self()
    sampler = spawn(fn -> sample_loop(deadline, parent, 0.0, 0) end)

    results =
      1..n
      |> Enum.map(fn wid -> Task.async(fn -> worker(wid, deadline) end) end)
      |> Task.await_many(:infinity)

    peak = receive do
      {:peak, mb, wc} -> %{mb: mb, wc: wc}
    after
      3000 -> %{mb: rss_mb(), wc: 0}
    end
    Process.exit(sampler, :kill)

    sum = Enum.reduce(results, %{ok: 0, unreachable: 0, render_fail: 0, citations: 0}, fn r, a ->
      %{ok: a.ok + r.ok, unreachable: a.unreachable + r.unreachable,
        render_fail: a.render_fail + r.render_fail, citations: a.citations + r.citations}
    end)

    total = sum.ok + sum.unreachable + sum.render_fail
    IO.puts("  peak RSS: #{peak.mb} MB / #{@cap_mb} MB cap   peak wasm procs: #{peak.wc}")
    IO.puts("  renders: #{sum.ok} ok  unreachable: #{sum.unreachable}  render-fail: #{sum.render_fail}  (of #{total})")
    IO.puts("  citations pulled: #{sum.citations}   throughput: #{Float.round(total / @duration, 1)} pages/s")

    %{n: n, peak_mb: peak.mb, peak_wc: peak.wc, ok: sum.ok,
      unreachable: sum.unreachable, render_fail: sum.render_fail, citations: sum.citations, total: total}
  end

  defp sample_loop(deadline, parent, peak_mb, peak_wc) do
    if System.monotonic_time(:millisecond) >= deadline do
      send(parent, {:peak, peak_mb, peak_wc})
    else
      mb = rss_mb()
      wc = wasm_count()
      Process.sleep(200)
      sample_loop(deadline, parent, max(peak_mb, mb), max(peak_wc, wc))
    end
  end

  def run do
    waves = System.get_env("WAVES", "4,8,16,32,64,96,128") |> String.split(",") |> Enum.map(&String.to_integer/1)
    IO.puts("Browser saturation — cap #{@cap_mb}MB, #{@duration}s/wave, distinct Wikipedia pages")
    IO.puts("baseline RSS (idle beam): #{rss_mb()} MB\n")

    summary =
      Enum.reduce_while(waves, [], fn n, acc ->
        r = wave(n)
        cond do
          r.peak_mb >= @cap_mb ->
            IO.puts("  ⛔ crossed #{@cap_mb}MB cap — this is the 1GB OOM point.")
            {:halt, [r | acc]}
          r.render_fail > r.ok * 0.5 and r.total > 0 ->
            IO.puts("  ⛔ render-fail rate > 50% — saturated.")
            {:halt, [r | acc]}
          true ->
            {:cont, [r | acc]}
        end
      end)
      |> Enum.reverse()

    IO.puts("\n══════════ SATURATION CURVE (cap #{@cap_mb}MB) ══════════")
    IO.puts("agents | peakRSS | wasmproc | ok | unreach | rfail | cites")
    Enum.each(summary, fn s ->
      :io.format("~6w | ~6.1f MB | ~8w | ~4w | ~7w | ~5w | ~w~n",
        [s.n, s.peak_mb, s.peak_wc, s.ok, s.unreachable, s.render_fail, s.citations])
    end)

    # marginal MB per concurrent wasm process, from the two widest clean waves
    clean = Enum.filter(summary, &(&1.peak_wc > 0))
    case clean do
      [_ | _] = cs when length(cs) >= 2 ->
        lo = hd(cs); hi = List.last(cs)
        dwc = hi.peak_wc - lo.peak_wc
        if dwc > 0 do
          per = Float.round((hi.peak_mb - lo.peak_mb) / dwc, 1)
          base = Float.round(lo.peak_mb - per * lo.peak_wc, 1)
          ceil_procs = if per > 0, do: round((@cap_mb - base) / per), else: 0
          IO.puts("\nmarginal: ~#{per} MB per concurrent wasm render process (BEAM base ~#{base} MB)")
          IO.puts("→ #{@cap_mb}MB ceiling ≈ #{ceil_procs} SIMULTANEOUS render processes")
          IO.puts("  (agents-per-GB is higher: agents waiting on the LLM hold no wasm process)")
        end
      _ -> :ok
    end
  end
end

BrowserSaturation.run()
