defmodule Nexus.Hook do
  @moduledoc """
  The `hook` kind — the reactive binding of the nexus (open standard). A hook declares **what to match**
  on the event bus and **which effects to run**:

      hook :auto_lint do
        match tags: [:file_edit]        # AST-valid; the #event/#file-edit tags live on the SOURCE unit
        run agent: "linter"
      end

      hook :activity do                 # the cloud Activity feed is just a hook with a `log` effect
        match tags: [:event]
        log
      end

  `match` is keyword-based (`tags:` / `kind:`) — NOT `#tags`, because a `#…` token is a comment inside
  the Elixir-AST block. The `#event #deploy` tags are authored on the *source* unit (parsed as refs)
  and ride along on each emitted event; the hook matches them by `tags:`. Effects are any call in the
  body (`show`, `log`, `run …`, `emit …`, `notify …`) resolved against the open `Nexus.Effects` registry.

  Compiled hooks register into `:persistent_term`; `Nexus.Events.emit/2` calls `matching/1` to find the
  hooks that fire for an event. Generic mechanism only — no Workbooks business here.
  """
  @reg {__MODULE__, :hooks}

  @non_effect ~w(match trigger visible_to title)a

  @doc "Compile a parsed `hook` node into a spec and register it. Returns the spec."
  def compile(%{kind: "hook", name: name} = node) do
    stmts = node |> Map.get(:ast) |> do_body() |> statements()

    spec = %{
      name: to_string(name),
      match: Enum.reduce(stmts, %{}, &match_clause/2),
      trigger: Enum.find_value(stmts, &trigger_clause/1),
      visible_to: Enum.find_value(stmts, fn {:visible_to, _, [r]} -> r; _ -> nil end),
      title: Enum.find_value(stmts, fn {:title, _, [t]} -> t; _ -> nil end) || to_string(name),
      effects: Enum.flat_map(stmts, &effect/1)
    }

    register(spec)
    arm_trigger(spec)
    spec
  end

  def compile(_), do: nil

  @doc "Register (or replace by name) a hook spec."
  def register(%{name: name} = spec) do
    :persistent_term.put(@reg, Map.put(all_map(), name, spec))
    :ok
  end

  @doc "All registered hook specs."
  def all, do: all_map() |> Map.values()
  defp all_map, do: :persistent_term.get(@reg, %{})

  @doc "Every registered hook whose `match` accepts `event`."
  def matching(event) when is_map(event), do: Enum.filter(all(), &matches?(&1.match, event))

  @doc "Does a hook's match spec accept this event? Empty match = matches every event."
  def matches?(match, event) do
    tags_ok?(match[:tags], event) and kind_ok?(match[:kind], event)
  end

  defp tags_ok?(nil, _), do: true
  defp tags_ok?(want, event) do
    # `tags: nil` (key present, value nil) is common (an emitter passing through a missing source field);
    # `Map.get(_, :tags, [])` only defaults on ABSENT keys, so coalesce nil here too.
    have = (event[:tags] || []) |> Enum.map(&to_string/1) |> MapSet.new()
    Enum.any?(want, fn t -> MapSet.member?(have, to_string(t)) end)
  end

  defp kind_ok?(nil, _), do: true
  defp kind_ok?(want, event), do: to_string(event[:kind]) in Enum.map(List.wrap(want), &to_string/1)

  # ── AST parsing ──────────────────────────────────────────────────────────────────────────────

  # `match tags: [...], kind: "..."` → accumulate into the match map.
  defp match_clause({:match, _meta, [opts]}, acc) when is_list(opts) do
    Enum.into(opts, acc, fn {k, v} -> {k, normalize_match(v)} end)
  end

  defp match_clause(_, acc), do: acc

  # `trigger every: "1d"` / `trigger cron: "0 9 * * 1"` / `trigger at: "14:00"` — a TIME binding.
  # A hook may have both a `match` (event-driven) and a `trigger` (time-driven); they're independent.
  defp trigger_clause({:trigger, _meta, [opts]}) when is_list(opts), do: opts
  defp trigger_clause({:trigger, _meta, [val]}), do: [val]
  defp trigger_clause(_), do: nil

  # Arm a time-triggered hook into Nexus.Scheduler — fires the hook's effects on the schedule.
  # Resilient: if the scheduler isn't up yet (early-boot compile), skip; it re-arms on recompile.
  defp arm_trigger(%{trigger: nil}), do: :ok

  defp arm_trigger(%{trigger: time, name: name, effects: effects}) do
    if Process.whereis(Nexus.Scheduler) do
      Nexus.Scheduler.arm(name, time, effects)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp normalize_match(v) when is_list(v), do: v
  defp normalize_match(v), do: [v]

  # Any statement that isn't match/visible_to/title is an effect call.
  defp effect({name, _meta, args}) when is_atom(name) and name not in @non_effect do
    [%{name: to_string(name), args: effect_args(args)}]
  end

  defp effect(_), do: []

  defp effect_args([opts]) when is_list(opts) do
    if Keyword.keyword?(opts), do: Map.new(opts), else: %{value: opts}
  end

  defp effect_args([val]), do: %{value: val}
  defp effect_args(_), do: %{}

  defp do_body({_kind, _meta, args}) when is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil

  defp statements(nil), do: []
  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(single), do: [single]
end
