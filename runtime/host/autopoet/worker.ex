defmodule Workbooks.Autopoet.Worker do
  @moduledoc """
  The autopoet WORKER (autopoiesis phase 3, wb-9ae) — the supervised process
  that closes the loop. It polls the metacognitive backlog (`Workbooks.Autopoet`)
  and, when there is an open `:capability` issue, runs the AUTOPOET AGENT against
  it: the agent authors/edits a toolkit (or skill/def) in its workspace to fill
  the gap, tests it, and the worker records the outcome on the issue.

  Mirrors `Workbooks.Keeper.Worker` (a GenServer with a `:tick` loop, synchronous
  run per tick), but simpler — no lifecycle, no crew gate. One issue per tick;
  an empty backlog costs nothing (no LLM call).

  CONFINEMENT (the autopoiesis law): the agent runs `exec: true` with its workdir
  set to the autopoet WORKSPACE — a mutable toolkits tree. The exec file tools
  are path-contained to that workdir (agent.ex `image_contained?/2`), so the
  autopoet physically cannot reach host source (`*.ex`) or a tenant's repo. It
  edits the DECLARATIVE config layer and nothing else.

  Env:
    * `WB_AUTOPOET=1`           — activate (wired in application.ex)
    * `WB_AUTOPOET_DEF`         — path to the autopoet agent def (org)
    * `WB_AUTOPOET_WORKDIR`     — the workspace (default `<WB_DATA>/autopoet/workspace`);
                                  its `toolkits/` subdir should be the WB_TOOLKITS_ROOT
    * `WB_AUTOPOET_INTERVAL_MS` — poll cadence (default 180_000 = 3 min)
    * `WB_AUTOPOET_RUN_TIMEOUT_MS` — per-issue wall clock (default 900_000 = 15 min)
  """
  use GenServer
  require Logger

  alias Workbooks.Autopoet

  @default_interval_ms 180_000
  @default_run_timeout_ms 900_000
  @max_steps 80

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Trigger one poll immediately (watched manual validation)."
  def run_once(server \\ __MODULE__), do: send(server, :tick)

  @doc "Live status for the public plane (persistent_term, never a blocking call)."
  def status do
    :persistent_term.get({__MODULE__, :status}, %{active: false, running: false, working: nil, last_run: nil})
  end

  defp put_status(patch), do: :persistent_term.put({__MODULE__, :status}, Map.merge(status(), patch))

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)

    case def_path() do
      nil ->
        Logger.info("Autopoet: no def (WB_AUTOPOET_DEF unset) — idle")
        {:ok, %{active: false}}

      path ->
        File.mkdir_p!(Path.join(workdir(), "toolkits"))
        # A crash/restart during a run leaves its issue stuck :doing (no longer
        # :open, so it'd never be re-picked). Reclaim orphans on boot.
        reset_orphans()
        Logger.info("Autopoet: activated — def=#{path} workspace=#{workdir()} poll=#{interval_ms()}ms")
        Process.send_after(self(), :tick, 5_000)
        put_status(%{active: true, running: false, last_run: nil})
        {:ok, %{active: true, def_path: path}}
    end
  end

  defp reset_orphans do
    for i <- Autopoet.list(:doing) do
      Autopoet.set_status(i.id, :open, "reclaimed: worker restarted mid-run")
    end
  end

  @impl true
  def handle_info(:tick, %{active: false} = s), do: {:noreply, s}

  def handle_info(:tick, %{def_path: path} = s) do
    case Autopoet.list(:open) |> Enum.filter(&(&1.kind == :capability)) |> top() do
      nil ->
        # empty backlog — idle, no LLM call
        put_status(%{running: false, working: nil, last_run: System.system_time(:second)})

      issue ->
        work(issue, path)
    end

    Process.send_after(self(), :tick, interval_ms())
    {:noreply, s}
  end

  # a crashing run must never take the worker down (linked Task EXITs trapped)
  def handle_info({:EXIT, _pid, _reason}, s), do: {:noreply, s}
  def handle_info(_other, s), do: {:noreply, s}

  # ── the run ───────────────────────────────────────────────────────────────

  defp work(issue, path) do
    Logger.info("Autopoet: working issue #{issue.id} — #{issue.title}")
    Autopoet.set_status(issue.id, :doing, "autopoet picked it up")
    put_status(%{running: true, working: issue.id, last_run: System.system_time(:second)})

    # Run in a supervised, time-bounded Task so a slow/killed/crashing run can
    # neither block the worker forever nor orphan the issue: a timeout or an
    # exit becomes a BLOCKED verdict that resets the issue to :open for a retry.
    result =
      try do
        org = File.read!(path)
        task = Task.async(fn ->
          run = Workbooks.AgentDef.run(org, task_for(issue), exec: true, workdir: workdir(), agent: "autopoet", max_steps: @max_steps)
          run[:result] || ""
        end)

        case Task.yield(task, run_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
          {:ok, res} -> res
          nil -> "BLOCKED: run exceeded #{run_timeout_ms()}ms wall clock"
          {:exit, reason} -> "BLOCKED: run exited — #{inspect(reason)}"
        end
      rescue
        e -> "BLOCKED: autopoet run errored — #{Exception.message(e)}"
      catch
        kind, reason -> "BLOCKED: autopoet run #{kind} — #{inspect(reason)}"
      end

    record_outcome(issue, result)
    put_status(%{running: false, working: nil})
  end

  # The autopoet ends its run with a verdict line we map onto the issue:
  #   DONE: …    → implemented + tested + registered (issue closed)
  #   HOST: …    → needs a new host primitive (re-kind :host, human lane)
  #   anything   → not finished; leave OPEN with the note so a later tick retries
  defp record_outcome(issue, result) do
    {verdict, note} = classify(result)

    case verdict do
      :done ->
        Autopoet.set_status(issue.id, :done, note)
        Logger.info("Autopoet: issue #{issue.id} DONE — #{note}")

      :host ->
        Autopoet.set_status(issue.id, :open, "needs host primitive: #{note}")
        Autopoet.rekind_host(issue.id)
        Logger.info("Autopoet: issue #{issue.id} → HOST lane — #{note}")

      :open ->
        Autopoet.set_status(issue.id, :open, "not finished this pass: #{note}")
        Logger.info("Autopoet: issue #{issue.id} left open — #{note}")
    end
  end

  @doc """
  Map an autopoet run's final text onto an issue verdict (pure — the worker's
  decision, extracted so it is testable). The first line's keyword wins; DONE
  beats HOST beats open.
  """
  @spec classify(String.t()) :: {:done | :host | :open, String.t()}
  def classify(result) do
    note = result |> to_string() |> String.trim() |> String.slice(0, 280)
    head = first_line(result)

    cond do
      Regex.match?(~r/\bDONE\b/i, head) -> {:done, note}
      Regex.match?(~r/\bHOST\b/i, head) -> {:host, note}
      true -> {:open, note}
    end
  end

  defp task_for(issue) do
    """
    IMPLEMENT THIS METACOGNITIVE ISSUE (filed by #{issue.tenant}):

    #{issue.title}

    Read the full issue at `../issues/#{issue.id}.org` (need + tried/evidence).
    Your workspace is a toolkits tree. Fill this gap by authoring a TOOLKIT (or a
    skill/def) here — follow the autopoiesis laws in your system prompt: edit the
    declarative layer only, never native code; TEST before you register (`wb
    toolkit verify <id>`); a gap that needs a NEW host primitive is not yours to
    build — end with `HOST: <what primitive>`.

    End your run with ONE verdict line:
      DONE: <what you built + how you verified it>
      HOST: <the host primitive this needs>
      BLOCKED: <why you could not, for a human>
    """
  end

  defp first_line(s), do: s |> String.trim() |> String.split("\n", parts: 2) |> hd()

  # newest-first list → take the most-seen (highest signal), then newest
  defp top([]), do: nil
  defp top(issues), do: issues |> Enum.sort_by(&{&1.seen, &1.id}, :desc) |> hd()

  # ── config ────────────────────────────────────────────────────────────────

  defp def_path, do: System.get_env("WB_AUTOPOET_DEF")

  defp workdir do
    System.get_env("WB_AUTOPOET_WORKDIR") ||
      Path.join([System.get_env("WB_DATA") || File.cwd!(), "autopoet", "workspace"])
  end

  defp interval_ms, do: env_int("WB_AUTOPOET_INTERVAL_MS", @default_interval_ms)
  defp run_timeout_ms, do: env_int("WB_AUTOPOET_RUN_TIMEOUT_MS", @default_run_timeout_ms)

  defp env_int(k, default) do
    case System.get_env(k) do
      nil -> default
      v -> case Integer.parse(v) do
        {n, _} -> n
        _ -> default
      end
    end
  end
end
