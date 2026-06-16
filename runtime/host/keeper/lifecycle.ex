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

  ## CONTEXT (singleton vs crew — wb-wc0.2)

  Every entry point takes an optional `ctx` (a `%Ctx{}`): the lifecycle spec path
  + the persistence/persistent_term NAMESPACE. This is the seam that lets ONE
  module serve both the singleton keeper (the lander) and N crew workers, with
  zero duplication:

    * `ctx/0` builds the DEFAULT context from env (`WB_LIFECYCLE_DEF`, files
      `lifecycle-pos` / `lifecycle-ran-<state>`, persistent_term key `:state`).
      The zero-arg public API (`current/0`, `advance/1`, `status/0`, …) uses it,
      so the singleton + every existing test keep working UNCHANGED.
    * `Crew` builds a per-agent context — `ctx(def_path: "...", ns: "wren")` —
      whose files are `lifecycle-pos-wren` / `lifecycle-ran-wren-<state>` and
      whose persistent_term key is `{__MODULE__, :state, "wren"}`. So two agents
      never share a cadence position.

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
  `runtime/examples/lifecycle.md` for the canonical spec.

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

  # A lifecycle context: which spec file to read + the persistence namespace.
  # `ns: nil` is the SINGLETON namespace (unsuffixed files, bare persistent_term
  # key) — the exact legacy behavior. A crew worker passes a non-nil `ns`.
  defmodule Ctx do
    @moduledoc false
    defstruct [:def_path, :ns]
  end

  # ── context ──────────────────────────────────────────────────────────────────

  @doc """
  Build a lifecycle context. With no opts it is the DEFAULT (env-driven, singleton
  namespace) context — every zero-arg public function uses this, preserving the
  singleton + tests verbatim. Crew passes `def_path:` + `ns:`.
  """
  def ctx(opts \\ []) do
    %Ctx{
      def_path: Keyword.get(opts, :def_path, System.get_env("WB_LIFECYCLE_DEF")),
      ns: Keyword.get(opts, :ns, nil)
    }
  end

  # ── activation ───────────────────────────────────────────────────────────────

  @doc "Path to the lifecycle spec, or nil (keeper then uses its env+prose path)."
  def def_path, do: System.get_env("WB_LIFECYCLE_DEF")

  @doc "True when a spec is set and parses into at least one state."
  def active?(ctx \\ ctx()), do: spec(ctx) != nil

  # ── current state ────────────────────────────────────────────────────────────

  @doc """
  What THIS tick is. Returns a map for the active spec, or nil when inactive:

      %{state: "wake_add", kind: :wake, hits: 1, repeat: 3, next_state: "wake_audit",
        gated: false, interval_ms: nil}

  `gated: true` means a `:MIN-INTERVAL:` time gate is still closed — the keeper
  should treat the tick as a no-op and hold position. Also mirrors the public
  shape to `:persistent_term` so `Keeper.status/0` can surface it.
  """
  def current(ctx \\ ctx()) do
    case spec(ctx) do
      nil ->
        nil

      states ->
        {name, hits} = position(ctx, states)
        s = states[name]

        view = %{
          state: name,
          kind: s.kind,
          hits: hits,
          repeat: s.repeat,
          next_state: s.next,
          gated: gated?(ctx, name, s),
          interval_ms: s.interval_ms
        }

        :persistent_term.put(pt_key(ctx), Map.take(view, [:state, :hits, :next_state, :kind]))
        view
    end
  end

  @doc "Public, persistent_term-readable position (for Keeper.status/0); nil when inactive."
  def status(ctx \\ ctx()) do
    case spec(ctx) do
      nil -> nil
      _ -> :persistent_term.get(pt_key(ctx), nil) || (current(ctx) && :persistent_term.get(pt_key(ctx), nil))
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
  def advance(outcome, ctx \\ ctx()) do
    case spec(ctx) do
      nil ->
        nil

      states ->
        {name, hits} = position(ctx, states)
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

        write_position(ctx, next)
        current(ctx)
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
  def mark_ran(name, ctx \\ ctx()) do
    File.write(ran_path(ctx, name), Integer.to_string(System.system_time(:second)))
  rescue
    _ -> :ok
  end

  # ── internals ────────────────────────────────────────────────────────────────

  # Parse + return the spec for this tick: %{name => state} | nil. Cheap to
  # re-read (one small file); kept dumb so a hot-edited spec is picked up.
  defp spec(ctx) do
    with path when is_binary(path) <- ctx.def_path,
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
  defp position(ctx, states) do
    case read_position(ctx) do
      {name, hits} when is_map_key(states, name) -> {name, hits}
      _ -> {start_from_disk(ctx, states), 0}
    end
  end

  defp start_from_disk(ctx, states) do
    case ctx.def_path && File.read(ctx.def_path) do
      {:ok, org} -> start_state(org, states)
      _ -> first_key(states)
    end
  end

  # A state is gated when its :MIN-INTERVAL: hasn't elapsed since it last ran.
  defp gated?(ctx, name, s) do
    case s.min_interval_ms do
      nil -> false
      ms -> elapsed_ms(ctx, name) < ms
    end
  end

  # ── persistence (on the data volume, beside keeper-last-run) ──────────────────
  # Filenames + the persistent_term key carry the namespace SUFFIX so crew agents
  # never collide; ns == nil reproduces the exact legacy (singleton) paths/keys.

  defp pos_path(ctx), do: Path.join(data_dir(), "lifecycle-pos#{suffix(ctx)}")
  defp ran_path(ctx, name), do: Path.join(data_dir(), "lifecycle-ran-#{ns_prefix(ctx)}#{name}")
  defp data_dir, do: System.get_env("WB_DATA") || File.cwd!()

  defp suffix(%Ctx{ns: nil}), do: ""
  defp suffix(%Ctx{ns: ns}), do: "-#{ns}"

  defp ns_prefix(%Ctx{ns: nil}), do: ""
  defp ns_prefix(%Ctx{ns: ns}), do: "#{ns}-"

  defp pt_key(%Ctx{ns: nil}), do: {__MODULE__, :state}
  defp pt_key(%Ctx{ns: ns}), do: {__MODULE__, :state, ns}

  defp read_position(ctx) do
    with {:ok, s} <- File.read(pos_path(ctx)),
         [name, hits] <- String.split(String.trim(s), " ", parts: 2),
         {n, _} <- Integer.parse(hits) do
      {name, n}
    else
      _ -> nil
    end
  end

  defp write_position(ctx, {name, hits}) do
    File.write(pos_path(ctx), "#{name} #{hits}")
  rescue
    _ -> :ok
  end

  defp elapsed_ms(ctx, name) do
    case File.read(ran_path(ctx, name)) do
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
