defmodule Workbooks.Keeper.Lifecycle do
  @moduledoc """
  The orchestrator agent's TRUE workflow (wb-2ku.3) — a deterministic state
  machine declared in native org, executed one transition per keeper tick.

  `plan.org` is the ongoing task DAG (it never "completes"); this is the
  separate, smaller thing: the agent's LIFECYCLE — `wake_add ×3 → wake_audit →
  rem → loop`, plus the failure rule (a killed/failed run retries the SAME state
  next tick, so the cadence position is never lost). It is the deterministic
  substrate of the persistent orchestrator (`Workbooks.Keeper`), not its
  replacement; what the agent does INSIDE a state stays non-deterministic (the
  agent def's job). Org owns the spec; this module just interprets and steps it.

  ## The spec (default `WB_LIFECYCLE_DEF`, e.g. /data/lifecycle.org)

  Headings are STATES; properties are the edges and gates (same conventions as
  `Workbooks.Workflow.Todo` — a `:PROPERTIES:` drawer, upcased keys):

      #+START: wake_add
      * wake_add
      :PROPERTIES:
      :KIND: wake            wake | rem  (wake → run agent def; rem → dream)
      :REPEAT: 3             hold N successful ticks before :NEXT: (default 1)
      :NEXT: wake_audit      the edge once :REPEAT: is satisfied
      :END:

  `:MIN-INTERVAL: 45m` on a state is a time gate — work is skipped (a no-op tick,
  position held) until that long has passed since the state last ran. See
  `runtime/examples/lifecycle.org` for the canonical spec.

  ## Position (survives restarts)

  `{state, hits}` persists at `WB_DATA/lifecycle-pos` next to `keeper-last-run`,
  so a redeploy resumes mid-cadence (e.g. on the 2nd of 3 adds). `current/0`
  reads it, `advance/1` steps it given the tick outcome (`:done | :failed |
  :killed`). The current state is mirrored to `:persistent_term` so the public
  plane (`Keeper.status/0` → `/_activity`) can read it without a GenServer call.

  No `WB_LIFECYCLE_DEF` / unparseable spec → `active?/0` is false and the keeper
  falls back to its env+prose behavior — zero regression when unset.
  """
  require Logger

  @pt_key {__MODULE__, :state}

  # ── activation ───────────────────────────────────────────────────────────────

  @doc "Path to the lifecycle spec, or nil (keeper then uses its env+prose path)."
  def def_path, do: System.get_env("WB_LIFECYCLE_DEF")

  @doc "True when a spec is set and parses into at least one state."
  def active?, do: spec() != nil

  # ── current state ────────────────────────────────────────────────────────────

  @doc """
  What THIS tick is. Returns a map for the active spec, or nil when inactive:

      %{state: "wake_add", kind: :wake, hits: 1, repeat: 3, next_state: "wake_audit",
        gated: false, interval_ms: nil}

  `gated: true` means a `:MIN-INTERVAL:` time gate is still closed — the keeper
  should treat the tick as a no-op and hold position. Also mirrors the public
  shape to `:persistent_term` so `Keeper.status/0` can surface it.
  """
  def current do
    case spec() do
      nil ->
        nil

      states ->
        {name, hits} = position(states)
        s = states[name]

        view = %{
          state: name,
          kind: s.kind,
          hits: hits,
          repeat: s.repeat,
          next_state: s.next,
          gated: gated?(name, s),
          interval_ms: s.interval_ms
        }

        :persistent_term.put(@pt_key, Map.take(view, [:state, :hits, :next_state, :kind]))
        view
    end
  end

  @doc "Public, persistent_term-readable position (for Keeper.status/0); nil when inactive."
  def status do
    case spec() do
      nil -> nil
      _ -> :persistent_term.get(@pt_key, nil) || (current() && :persistent_term.get(@pt_key, nil))
    end
  end

  # ── advance ──────────────────────────────────────────────────────────────────

  @doc """
  Step the machine after a tick. `outcome`:

    * `:done`    — a successful run: increment hits; once hits == :REPEAT:, take
      `:NEXT:` and reset hits to 0.
    * `:no_work` — the run found NOTHING its state's kind may do (wb-2ku.10:
      e.g. a wake_add facing a board whose only NEXT is plan-run work). The
      state's remaining :REPEAT: hits are collapsed — take `:NEXT:` NOW. This
      is a fast-forward of repeats only, never a skip: every state in the
      declared order still runs, so audits and dreams keep their cadence.
    * `:failed` / `:killed` — retry the SAME state next tick; position unchanged
      (the cadence is preserved across crashes/timeouts).

  Returns the NEW current view (same shape as `current/0`), or nil if inactive.
  """
  def advance(outcome) do
    case spec() do
      nil ->
        nil

      states ->
        {name, hits} = position(states)
        s = states[name]

        next =
          case outcome do
            :done ->
              if hits + 1 >= s.repeat, do: {s.next || name, 0}, else: {name, hits + 1}

            :no_work ->
              {s.next || name, 0}

            _ ->
              # :failed | :killed → hold position, retry the same state next tick.
              {name, hits}
          end

        write_position(next)
        current()
    end
  end

  # ── spec parse (self-contained, mirrors workflow/todo.ex conventions) ─────────

  @doc "Parse a lifecycle org string into %{name => state}, or nil. Public for tests."
  def parse(org) when is_binary(org) do
    states =
      Regex.scan(~r/^\*\s+(\S+)\s*\n(.*?)(?=^\*\s|\z)/ms, org)
      |> Enum.map(fn [_, name, body] ->
        p = drawer_props(body)

        {name,
         %{
           name: name,
           kind: kind(p["KIND"]),
           repeat: int(p["REPEAT"], 1),
           next: p["NEXT"],
           min_interval_ms: dur_ms(p["MIN-INTERVAL"] || p["MIN_INTERVAL"]),
           interval_ms: int(p["INTERVAL-MS"] || p["INTERVAL_MS"], nil)
         }}
      end)
      |> Map.new()

    if map_size(states) == 0, do: nil, else: states
  end

  @doc "The start state of a parsed spec (#+START:, else the first heading)."
  def start_state(org, states) do
    case Regex.run(~r/^#\+START:\s*(\S+)/m, org) do
      [_, s] -> if Map.has_key?(states, s), do: s, else: first_key(states)
      _ -> first_key(states)
    end
  end

  @doc "Record that `name` ran now (resets its min-interval gate). Keeper calls this."
  def mark_ran(name) do
    File.write(ran_path(name), Integer.to_string(System.system_time(:second)))
  rescue
    _ -> :ok
  end

  # ── internals ────────────────────────────────────────────────────────────────

  # Parse + return the spec for this tick: %{name => state} | nil. Cheap to
  # re-read (one small file); kept dumb so a hot-edited spec is picked up.
  defp spec do
    with path when is_binary(path) <- def_path(),
         {:ok, org} <- File.read(path),
         states when is_map(states) <- parse(org) do
      states
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Current {state, hits}: persisted position, validated against the spec; an
  # unknown/absent state resets to the spec's start.
  defp position(states) do
    case read_position() do
      {name, hits} when is_map_key(states, name) -> {name, hits}
      _ -> {start_from_disk(states), 0}
    end
  end

  defp start_from_disk(states) do
    case def_path() && File.read(def_path()) do
      {:ok, org} -> start_state(org, states)
      _ -> first_key(states)
    end
  end

  # A state is gated when its :MIN-INTERVAL: hasn't elapsed since it last ran.
  defp gated?(name, s) do
    case s.min_interval_ms do
      nil -> false
      ms -> elapsed_ms(name) < ms
    end
  end

  # ── persistence (on the data volume, beside keeper-last-run) ──────────────────

  defp pos_path, do: Path.join(data_dir(), "lifecycle-pos")
  defp ran_path(name), do: Path.join(data_dir(), "lifecycle-ran-#{name}")
  defp data_dir, do: System.get_env("WB_DATA") || File.cwd!()

  defp read_position do
    with {:ok, s} <- File.read(pos_path()),
         [name, hits] <- String.split(String.trim(s), " ", parts: 2),
         {n, _} <- Integer.parse(hits) do
      {name, n}
    else
      _ -> nil
    end
  end

  defp write_position({name, hits}) do
    File.write(pos_path(), "#{name} #{hits}")
  rescue
    _ -> :ok
  end

  defp elapsed_ms(name) do
    case File.read(ran_path(name)) do
      {:ok, s} ->
        case Integer.parse(String.trim(s)) do
          {ts, _} -> (System.system_time(:second) - ts) * 1000
          _ -> :infinity
        end

      # never ran → gate is open.
      _ ->
        :infinity
    end
  end

  # ── tiny parse helpers ────────────────────────────────────────────────────────

  defp drawer_props(body) do
    case Regex.run(~r/:PROPERTIES:\n(.*?)\n\s*:END:/s, body) do
      [_, drawer] ->
        Regex.scan(~r/^\s*:([A-Za-z][\w-]*):[ \t]+(.+?)\s*$/m, drawer)
        |> Map.new(fn [_, k, v] -> {String.upcase(k), String.trim(v)} end)

      _ ->
        %{}
    end
  end

  defp kind("rem"), do: :rem
  defp kind(_), do: :wake

  defp int(nil, default), do: default
  defp int(s, default), do: (case Integer.parse(s), do: ({n, _} -> n; _ -> default))

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

  defp first_key(states), do: states |> Map.keys() |> Enum.sort() |> List.first()
end
