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
    * `WB_AUTOPOET_DEF`         — path to the autopoet agent def (HTML `<work-agent>`)
    * `WB_AUTOPOET_WORKDIR`     — the workspace (default `<WB_DATA>/autopoet/workspace`);
                                  the workspace itself IS the toolkits root — the
                                  worker pins WB_TOOLKITS_ROOT to it at init so the
                                  autopoet authors and verifies in the same tree
    * `WB_AUTOPOET_INTERVAL_MS` — poll cadence (default 180_000 = 3 min)
    * `WB_AUTOPOET_RUN_TIMEOUT_MS` — per-issue wall clock (default 900_000 = 15 min)
  """
  use GenServer
  require Logger

  alias Workbooks.Autopoet

  @default_interval_ms 180_000
  @default_run_timeout_ms 900_000
  @max_steps 80

  # The autopoet is a SYSTEM def, not tenant data — it must be present on every
  # runtime box so `WB_AUTOPOET=1` (or an on-demand `work autopoet tick`) just works,
  # with no manual file placement (the CI image ships only the release, not the
  # repo's examples/). Embed the canonical def at COMPILE time so it is part of the
  # BEAM and cannot be missing in prod; `WB_AUTOPOET_DEF` still overrides it (the
  # def is editable config — a path lets the autopoet evolve its own def).
  @autopoet_def_path Path.join(__DIR__, "../../priv/autopoet/autopoet.html") |> Path.expand()
  @external_resource @autopoet_def_path
  @embedded_def File.read!(@autopoet_def_path)

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

    # The def always exists (embedded at compile time; WB_AUTOPOET_DEF overrides),
    # so a started worker is always active — the GenServer itself is gated upstream
    # by WB_AUTOPOET=1 in application.ex.
    ensure_workspace()
    # A crash/restart during a run leaves its issue stuck :doing (no longer :open,
    # so it'd never be re-picked). Reclaim orphans on boot.
    reset_orphans()
    Logger.info("Autopoet: activated — def=#{def_source()} workspace=#{workdir()} poll=#{interval_ms()}ms")
    Process.send_after(self(), :tick, 5_000)
    put_status(%{active: true, running: false, last_run: nil})
    {:ok, %{active: true}}
  end

  # The workspace IS the toolkits root (the def's contract: "your working
  # directory IS the toolkits tree"). Pin WB_TOOLKITS_ROOT to it so the autopoet's
  # OWN `work toolkit verify`/`list` resolve to exactly where it authors — otherwise
  # it cannot verify its own work and falls back to claiming DONE on a shell
  # smoke-test (the iter-9 false-DONE root cause). Idempotent — safe to call from
  # both the GenServer init and an on-demand `drain_one/0`.
  defp ensure_workspace do
    File.mkdir_p!(workdir())
    System.put_env("WB_TOOLKITS_ROOT", workdir())
  end

  defp reset_orphans do
    for i <- Autopoet.list(:doing) do
      Autopoet.set_status(i.id, :open, "reclaimed: worker restarted mid-run")
    end
  end

  @doc """
  Drain ONE issue on demand — the unit of autopoet work, callable WITHOUT the
  GenServer (e.g. `work autopoet tick` on a triggered job). The backlog is bursty
  and small, so a triggered drain is the efficient shape — no always-on poller
  idling on an empty backlog. Returns:
    * `{:worked, id, verdict}` — ran an issue (verdict ∈ :done | :host | :open)
    * `:empty`                 — no open :capability issue (no LLM call)

  The def is embedded (always present), so there is no "inactive" state — the
  on-demand surface is always available; only the always-on GenServer is gated by
  WB_AUTOPOET=1.
  """
  @spec drain_one() :: {:worked, String.t(), atom()} | :empty
  def drain_one do
    ensure_workspace()

    case Autopoet.list(:open) |> Enum.filter(&(&1.kind == :capability)) |> top() do
      nil -> :empty
      issue -> {:worked, issue.id, work(issue)}
    end
  end

  @impl true
  def handle_info(:tick, %{active: false} = s), do: {:noreply, s}

  def handle_info(:tick, %{active: true} = s) do
    case drain_one() do
      :empty -> put_status(%{running: false, working: nil, last_run: System.system_time(:second)})
      _ -> :ok
    end

    Process.send_after(self(), :tick, interval_ms())
    {:noreply, s}
  end

  # a crashing run must never take the worker down (linked Task EXITs trapped)
  def handle_info({:EXIT, _pid, _reason}, s), do: {:noreply, s}
  def handle_info(_other, s), do: {:noreply, s}

  # ── the run ───────────────────────────────────────────────────────────────

  defp work(issue) do
    Logger.info("Autopoet: working issue #{issue.id} — #{issue.title}")
    Autopoet.set_status(issue.id, :doing, "autopoet picked it up")
    put_status(%{running: true, working: issue.id, last_run: System.system_time(:second)})

    # Snapshot the toolkits present BEFORE the run, so the honesty gate verifies
    # only what THIS run authored (a prior run's clean toolkit must not launder a
    # new run's false DONE).
    before = toolkit_names()

    # Run in a supervised, time-bounded Task so a slow/killed/crashing run can
    # neither block the worker forever nor orphan the issue: a timeout or an
    # exit becomes a BLOCKED verdict that resets the issue to :open for a retry.
    result =
      try do
        def_html = autopoet_def()
        body = case Autopoet.read_body(issue.id) do
          {:ok, b} -> b
          _ -> ""
        end
        task = Task.async(fn ->
          run = Workbooks.AgentDef.run(def_html, task_for(issue, body), exec: true, workdir: workdir(), agent: "autopoet", max_steps: @max_steps)
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

    verdict = record_outcome(issue, result, before)
    put_status(%{running: false, working: nil})
    verdict
  end

  # The autopoet ends its run with a verdict line we map onto the issue:
  #   DONE: …    → implemented + tested + registered (issue closed)
  #   HOST: …    → needs a new host primitive (re-kind :host, human lane)
  #   anything   → not finished; leave OPEN with the note so a later tick retries
  #
  # HONESTY GATE: a self-reported DONE is the agent grading its own homework —
  # and it over-claims (it once returned "DONE … registration blocked by host
  # gap" on a stub toolkit that fails verify). So the worker does NOT trust the
  # word DONE: it INDEPENDENTLY runs `work toolkit verify` on whatever toolkit this
  # run newly authored. DONE is honored only if a fresh toolkit verifies clean;
  # otherwise the issue stays OPEN with the verify output as evidence. Same trust
  # boundary as the confinement guard — enforce host-side, don't trust the agent.
  defp record_outcome(issue, result, before) do
    {verdict, note} = classify(result) |> honesty_gate(before)

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

    verdict
  end

  # Independent verification of a DONE. `before` is the toolkit set snapshotted
  # before the run; the gate verifies only toolkits authored THIS run.
  defp honesty_gate({:done, note}, before), do: decide(note, verify_new(before))
  defp honesty_gate({verdict, note}, _before), do: {verdict, note}

  @doc """
  Reconcile a DONE note with the worker's independent verification result (pure,
  so it is testable without the filesystem). DONE survives only on `{:ok,…}`;
  a failed or absent verification downgrades it to OPEN with the evidence.
  """
  @spec decide(String.t(), {:ok, [String.t()]} | {:fail, String.t()} | :none) ::
          {:done | :open, String.t()}
  def decide(note, {:ok, names}),
    do: {:done, note <> " ✔ worker-verified: #{Enum.join(names, ", ")}"}

  def decide(_note, {:fail, report}),
    do: {:open, "DONE claimed but the worker's `work toolkit verify` FAILED — an unverified capability is not shipped:\n#{report}"}

  def decide(_note, :none),
    do: {:open, "DONE claimed but this run authored no verifiable toolkit (worker check). If you edited an existing artifact, say which and re-run; nothing was registered to verify."}

  # Toolkits THIS run added (subdirs of the workspace that hold a manifest.html),
  # each independently verified. Clean = verify output with no ✗ and not
  # "no such toolkit". The workspace IS the toolkits root (the def's contract:
  # "your working directory IS the toolkits tree"), so verify reads it directly.
  defp verify_new(before) do
    root = workdir()
    fresh = toolkit_names() -- before

    reports = Enum.map(fresh, fn n -> {n, Workbooks.Toolkits.verify_text(n, root)} end)
    clean = for {n, r} <- reports, not String.contains?(r, "✗"), not String.contains?(r, "no such toolkit"), do: n

    cond do
      fresh == [] -> :none
      clean != [] -> {:ok, clean}
      true -> {:fail, Enum.map_join(reports, "\n\n", fn {n, r} -> "#{n}:\n#{r}" end)}
    end
  rescue
    # verify needs the discovery services; if they are down, do not silently pass
    # a DONE — surface it as unverified (stays open).
    e -> {:fail, "worker verify errored: #{Exception.message(e)}"}
  end

  defp toolkit_names do
    root = workdir()
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&File.exists?(Path.join([root, &1, "manifest.html"])))
        |> Enum.sort()

      _ ->
        []
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

  defp task_for(issue, body \\ "") do
    """
    IMPLEMENT THIS METACOGNITIVE ISSUE (filed by #{issue.tenant}):

    #{issue.title}

    THE FULL ISSUE (need + tried/evidence) — it is inlined here; do NOT try to
    read it from `../issues/…` (that path is OUTSIDE your workspace and your file
    tools are confined to the workspace, by design):

    #{String.trim(body)}

    Your workspace is a toolkits tree. Fill this gap by authoring a TOOLKIT (or a
    skill/def) here. AUTHOR FILES WITH THE `vfs_write` TOOL — it writes to your
    workspace and creates parent dirs for you (so `vfs_write rss/manifest.html`
    and `vfs_write rss/skills/parse.md` just work). Do NOT author files with the
    `shell` tool (`cat > …`, `echo > …`, `mkdir`): the sandbox shell has no
    `mkdir`, will not create parent dirs, and its cwd is not stable between
    commands — shell redirection is for running commands, not writing files.
    Follow the autopoiesis laws in your system prompt: edit the declarative layer
    only, never native code; TEST before you register (`work toolkit verify <id>`);
    a gap that needs a NEW host primitive is not yours to build — end with
    `HOST: <what primitive>`.

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

  # The autopoet def CONTENT (a `<work-agent>` HTML def): WB_AUTOPOET_DEF (a path)
  # overrides the embedded default, so the autopoet can evolve its own def without
  # a rebuild.
  defp autopoet_def do
    case System.get_env("WB_AUTOPOET_DEF") do
      p when is_binary(p) and p != "" -> File.read!(p)
      _ -> @embedded_def
    end
  end

  defp def_source, do: System.get_env("WB_AUTOPOET_DEF") || "embedded"

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
