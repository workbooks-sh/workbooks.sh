defmodule Workbooks.Keeper.Crew do
  @moduledoc """
  The bit.ml CREW runtime (wb-wc0.2) — a multi-agent keeper.

  When `WB_CREW_DEF` points at a CREW MANIFEST (a declared org file, parsed like
  `lifecycle.org`), this supervisor starts ONE keeper `Worker` per crew member.
  Each worker is a full instance of the keeper tick engine with its OWN def, its
  OWN lifecycle, and persistence keys NAMESPACED by agent name — so N agents tick
  independently, in parallel, with no shared cadence state.

  The singleton `Workbooks.Keeper` (driven by `WB_KEEPER_DEF`) is unaffected and
  the two never both run: `Workbooks.Application` starts the crew when `WB_CREW_DEF`
  is set, else the singleton when `WB_KEEPER_DEF` is set, else neither.

  ## The crew manifest

      #+TITLE: crew
      * wren
      :PROPERTIES:
      :DEF: /data/agents/writer.html         (required — the agent def to run)
      :LIFECYCLE: /data/lifecycles/writer.org (optional — absent → interval ticks)
      :INTERVAL: 10m                          (fallback cadence; default 1h)
      :END:
      * moss
      :PROPERTIES:
      :DEF: /data/agents/editor.html
      :END:

  Headings are AGENT NAMES; the `:PROPERTIES:` drawer carries each agent's config
  (same drawer conventions as the lifecycle spec). A member with no `:DEF:` is
  skipped (logged). Durations accept `10m | 2h | 90s | <bare ms>`.

  ## Stagger + concurrency

    * Workers START staggered (default 30s apart, `WB_CREW_STAGGER_MS`) so agents
      visibly overlap on the wire but don't thundering-herd the LLM at boot.
    * Runs themselves are PARALLEL — each worker keeps its own wall-clock bound —
      but a GLOBAL cap (`Workbooks.Keeper.Crew.Gate`, default 2,
      `WB_CREW_MAX_CONCURRENT`) admits at most N runs at once and QUEUES the rest,
      protecting the box (and the LLM budget).

  ## Board claims are a DEF-LEVEL protocol, not runtime-enforced

  When crew members share a task board, claiming a task so two agents don't grab
  the same one is the AGENTS' protocol: a board STATE change + an `:AGENT:`
  property the claiming agent commits to git BEFORE doing the work, visible to
  peers. The runtime does NOT lock tasks — it only ISOLATES runs (per-worker
  workdir/state) and THROTTLES concurrency (the gate). Coordination correctness
  lives in the def + the board, where the non-deterministic interior already does.
  """
  use Supervisor
  require Logger

  alias Workbooks.Keeper.{Worker, Lifecycle, Crew}

  @default_stagger_ms 30_000
  @default_interval_ms 3_600_000

  # ── activation ────────────────────────────────────────────────────────────────

  @doc "True when WB_CREW_DEF is set and parses into at least one agent with a :DEF:."
  def active?, do: members() != []

  @doc "Path to the crew manifest, or nil."
  def def_path, do: System.get_env("WB_CREW_DEF")

  # ── supervisor ────────────────────────────────────────────────────────────────

  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    ms = members()
    Logger.info("Crew: starting #{length(ms)} keeper worker(s) from #{def_path()}")

    # The global concurrency gate is the FIRST child so every worker can borrow a
    # slot from it; workers start after (staggered via cfg.start_delay_ms).
    children =
      [{Crew.Gate, max: max_concurrent()}] ++
        (ms |> Enum.with_index() |> Enum.map(&worker_spec/1))

    Supervisor.init(children, strategy: :one_for_one)
  end

  # One Worker per member, registered under a per-agent via the worker name; the
  # i-th worker's first tick is staggered by i × stagger so the crew fans in.
  defp worker_spec({m, i}) do
    cfg = %Worker.Cfg{
      name: worker_name(m.name),
      agent: m.name,
      def_path: m.def_path,
      # Each agent gets its own namespaced lifecycle ctx (or nil → interval ticks).
      lifecycle_ctx: m.lifecycle && Lifecycle.ctx(def_path: m.lifecycle, ns: m.name),
      key_suffix: "-#{m.name}",
      interval_ms: m.interval_ms,
      run_timeout_ms: nil,
      continuous: false,
      breather_ms: 45_000,
      start_delay_ms: i * stagger_ms(),
      acquire: fn -> Crew.Gate.acquire() end,
      release: fn -> Crew.Gate.release() end
    }

    %{id: {:crew_worker, m.name}, start: {Worker, :start_link, [cfg]}}
  end

  @doc "The registered name for agent `name`'s worker."
  def worker_name(name), do: :"#{__MODULE__}.#{name}"

  # ── manifest parse ────────────────────────────────────────────────────────────

  @doc """
  Parse a crew manifest org string into a list of member maps (ordered), or `[]`.
  A member needs a `:DEF:`; one without is dropped. Public for tests.
  """
  def parse(org) when is_binary(org) do
    Regex.scan(~r/^\*\s+(\S+)\s*\n(.*?)(?=^\*\s|\z)/ms, org)
    |> Enum.map(fn [_, name, body] ->
      p = drawer_props(body)

      %{
        name: name,
        def_path: p["DEF"],
        lifecycle: p["LIFECYCLE"],
        interval_ms: dur_ms(p["INTERVAL"]) || @default_interval_ms
      }
    end)
    |> Enum.filter(& &1.def_path)
  end

  # The parsed members from WB_CREW_DEF (re-read on each call; cheap, one small file).
  defp members do
    with path when is_binary(path) <- def_path(),
         {:ok, org} <- File.read(path) do
      parse(org)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "Member names currently declared (for /_activity to enumerate agents)."
  def member_names, do: Enum.map(members(), & &1.name)

  @doc """
  Per-agent context tuples `{name, key_suffix, lifecycle_ctx}` — what the public
  plane needs to read each worker's status + lifecycle without a GenServer call.
  """
  def agent_contexts do
    Enum.map(members(), fn m ->
      {m.name, "-#{m.name}", m.lifecycle && Lifecycle.ctx(def_path: m.lifecycle, ns: m.name)}
    end)
  end

  # ── knobs ─────────────────────────────────────────────────────────────────────

  defp stagger_ms, do: env_int("WB_CREW_STAGGER_MS") || @default_stagger_ms
  defp max_concurrent, do: env_int("WB_CREW_MAX_CONCURRENT") || 2

  defp env_int(var) do
    case System.get_env(var) do
      nil -> nil
      s -> case Integer.parse(s), do: ({n, _} -> n; _ -> nil)
    end
  end

  # ── tiny parse helpers (shared shape with Lifecycle's drawer parsing) ──────────

  defp drawer_props(body) do
    case Regex.run(~r/:PROPERTIES:\n(.*?)\n\s*:END:/s, body) do
      [_, drawer] ->
        Regex.scan(~r/^\s*:([A-Za-z][\w-]*):[ \t]+(.+?)\s*$/m, drawer)
        |> Map.new(fn [_, k, v] -> {String.upcase(k), String.trim(v)} end)

      _ ->
        %{}
    end
  end

  # "45m" | "2h" | "90s" | "3000000" (bare ms) → milliseconds | nil.
  defp dur_ms(nil), do: nil

  defp dur_ms(s) do
    case Regex.run(~r/^\s*(\d+)\s*([smh]?)\s*$/, s) do
      [_, n, unit] ->
        v = String.to_integer(n)

        case unit do
          "s" -> v * 1000
          "m" -> v * 60_000
          "h" -> v * 3_600_000
          _ -> v
        end

      _ ->
        nil
    end
  end
end
