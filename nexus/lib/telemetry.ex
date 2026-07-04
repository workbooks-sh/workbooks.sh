defmodule Nexus.Telemetry do
  @moduledoc """
  §10 (execution reality) — the agent run ledger. When an agent runs, its real
  behaviour — turns, tokens, wall-clock, the kits it actually invoked, how it
  finished — is recorded here, keyed by the agent's canonical identity (§1,
  `Nexus.Uid.key`). `overlay/0` projects the ledger into a `Nexus.Overlay`
  that the pure graph joins at query time (`Graph.with_overlay/2`) to fill
  `facets.observed`. This is what lets *declared* (the grants + deps the author
  wrote) be checked against *observed* (what the agent did) under one identity.

  A GenServer holding `unit_key => [run]`. Recording is fire-and-forget; the agent
  loop is never blocked on it.

  Runs are durable (Autopoiesis v3 phase 0.1 — learning eats outcomes, so outcomes
  must survive a reboot): every record appends a crash-tolerant framed term
  (`<<size::32, term_to_binary({key, run})>>` — a torn tail frame is skipped on read,
  the same format the trace capture uses) to `<durable_dir>/telemetry/runs.etfs`,
  replayed at init. Ring semantics: the newest 200 runs per unit are kept; the log
  is compacted in place once enough appends accumulate. Persistence failure never
  blocks recording — the ledger degrades to in-memory rather than crashing an agent.
  """
  use GenServer

  alias Nexus.{Uid, Overlay}

  @ring 200
  @compact_every 5_000

  # ── client ──

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # Lazily start outside a supervision tree (tests, escript) without racing.
  defp ensure do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc "Record one agent run for `unit` (the literate unit name). Fire-and-forget."
  def record(nil, _run), do: :ok

  def record(unit, run) when is_map(run) do
    ensure()
    GenServer.cast(__MODULE__, {:record, Uid.key(unit), run})
  end

  @doc "Every recorded run for a unit (most recent first)."
  def runs(unit) do
    ensure()
    GenServer.call(__MODULE__, {:runs, Uid.key(unit)})
  end

  @doc "The aggregated observed facet for a unit, or nil if it never ran."
  def summary(unit) do
    case runs(unit) do
      [] -> nil
      rs -> aggregate(rs)
    end
  end

  @doc """
  Every unit's aggregated summary, keyed by unit identity — the autopoet's SENSE input (Autopoiesis v2
  — wb-a6u3.11). A pure read of the execution-reality ledger; the heartbeat scans this for drift.
  """
  def ledger do
    ensure()
    GenServer.call(__MODULE__, :all)
    |> Map.new(fn {key, rs} -> {key, aggregate(rs)} end)
  end

  @doc """
  Units the autopoet should look at — drift/inefficiency signals derived from the ledger. Each entry is
  `{unit_key, summary, [reason]}`, e.g. `{:error_rate, 0.6}` (failing too often) or `:no_success` (never
  once succeeded). Only units with enough runs to be meaningful are considered. Pure read, no effects —
  this is what a heartbeat tick turns into candidate self-improvement work (the founding web_search case:
  a unit burning most of its steps on a tool that returns nothing).
  """
  def concerns(opts \\ []) do
    err_rate = Keyword.get(opts, :error_rate, 0.3)
    min_runs = Keyword.get(opts, :min_runs, 3)

    for {key, s} <- ledger(), s.runs >= min_runs, reasons = concern_reasons(s, err_rate), reasons != [] do
      {key, s, reasons}
    end
  end

  defp concern_reasons(s, err_rate) do
    rate = s.errors / max(s.runs, 1)

    []
    |> add_if(rate >= err_rate, {:error_rate, Float.round(rate, 2)})
    |> add_if(Map.get(s.statuses, :ok, 0) == 0, :no_success)
  end

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list

  @doc "Project the whole ledger into a reality overlay for `Graph.with_overlay/2`."
  def overlay do
    ensure()
    state = GenServer.call(__MODULE__, :all)

    Enum.reduce(state, Overlay.new(), fn {key, rs}, ov ->
      Overlay.put_observed(ov, key, aggregate(rs))
    end)
  end

  @doc "Wipe the ledger (test/maintenance)."
  def reset do
    ensure()
    GenServer.call(__MODULE__, :reset)
  end

  # ── aggregation ──

  defp aggregate(runs) do
    n = length(runs)

    %{
      runs: n,
      turns: sum(runs, & &1.turns),
      tokens: sum(runs, &get_in(&1, [:tokens, :total])),
      latency_ms: div(sum(runs, & &1.latency_ms), max(n, 1)),
      tools_used: runs |> Enum.flat_map(&Map.keys(&1.tools || %{})) |> Enum.uniq(),
      statuses: runs |> Enum.frequencies_by(& &1.status),
      errors: Enum.count(runs, &(&1.status == :error))
    }
  end

  defp sum(runs, fun), do: Enum.reduce(runs, 0, fn r, acc -> acc + (fun.(r) || 0) end)

  # ── server ──

  @impl true
  def init(_), do: {:ok, %{runs: load(), io: nil, appends: 0}}

  @impl true
  def handle_cast({:record, key, run}, state) do
    state =
      state
      |> Map.update!(:runs, fn runs ->
        Map.update(runs, key, [run], &Enum.take([run | &1], @ring))
      end)
      |> append({key, run})

    if state.appends >= @compact_every, do: {:noreply, compact(state)}, else: {:noreply, state}
  end

  @impl true
  def handle_call({:runs, key}, _from, state), do: {:reply, Map.get(state.runs, key, []), state}
  def handle_call(:all, _from, state), do: {:reply, state.runs, state}

  def handle_call(:reset, _from, state) do
    if state.io, do: File.close(state.io)
    File.rm(log_path())
    {:reply, :ok, %{runs: %{}, io: nil, appends: 0}}
  end

  # ── persistence (durable ring log) ──

  defp dir,
    do: Application.get_env(:nexus, :telemetry_dir) || Path.join(Nexus.Paths.durable_dir(), "telemetry")

  defp log_path, do: Path.join(dir(), "runs.etfs")

  defp append(state, term) do
    case ensure_io(state) do
      %{io: nil} = s ->
        s

      s ->
        blob = :erlang.term_to_binary(term)

        case :file.write(s.io, <<byte_size(blob)::32, blob::binary>>) do
          :ok -> %{s | appends: s.appends + 1}
          _ -> %{s | io: nil}
        end
    end
  end

  defp ensure_io(%{io: nil} = state) do
    with :ok <- File.mkdir_p(dir()),
         {:ok, io} <- File.open(log_path(), [:append, :binary, :raw]) do
      %{state | io: io}
    else
      _ -> state
    end
  end

  defp ensure_io(state), do: state

  # Rewrite the log from the in-memory ring (oldest-first per key) so it stops growing.
  defp compact(state) do
    if state.io, do: File.close(state.io)
    tmp = log_path() <> ".tmp"

    frames =
      for {key, rs} <- state.runs, run <- Enum.reverse(rs), into: <<>> do
        blob = :erlang.term_to_binary({key, run})
        <<byte_size(blob)::32, blob::binary>>
      end

    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(tmp, frames),
         :ok <- File.rename(tmp, log_path()) do
      :ok
    else
      _ -> File.rm(tmp)
    end

    %{state | io: nil, appends: 0}
  end

  # Replay the log at boot; a torn tail frame (crash mid-write) is skipped silently.
  defp load do
    case File.read(log_path()) do
      {:ok, bin} -> load_frames(bin, %{})
      _ -> %{}
    end
  end

  defp load_frames(<<size::32, blob::binary-size(size), rest::binary>>, acc) do
    acc =
      try do
        {key, run} = :erlang.binary_to_term(blob)
        Map.update(acc, key, [run], &Enum.take([run | &1], @ring))
      rescue
        _ -> acc
      end

    load_frames(rest, acc)
  end

  defp load_frames(_torn_or_empty, acc), do: acc
end
