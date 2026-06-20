defmodule Nexus.Events do
  @moduledoc """
  The system-wide **event bus** — the canonical reactive substrate of the nexus (open standard,
  generic mechanism only). Flow:

      #event-tagged unit fires  ──▶  Nexus.Events.emit(event)
                                        ├─▶ run every matching `hook`'s effects (async, isolated)
                                        └─▶ broadcast to live subscribers (websocket / SSE tail)

  An event is a plain map (the shape of a `resource`/`record` — `kind`, `actor`, `target`, `tags`,
  `at`, …). Hooks (`Nexus.Hook`) declare `match → effects`; effects (`Nexus.Effects`) run in supervised
  tasks so a slow/failing effect can't stall the emitter or its siblings. A **loop guard** (causation
  depth) stops `emit → hook → emit` cycles.

  Persistence + display are NOT here — the cloud dashboard opts in by registering a `log` effect
  (durable `resource :Event` + the Activity page). A bare nexus emits + reacts without persisting.
  """
  require Logger

  @subs Nexus.Events.Registry
  @tasksup Nexus.Events.TaskSup
  @key :events
  @max_depth 8

  @doc "Child specs for the supervision tree — a duplicate-key Registry (subscribers) + a Task.Supervisor."
  def child_specs do
    [
      {Registry, keys: :duplicate, name: @subs},
      {Task.Supervisor, name: @tasksup}
    ]
  end

  @doc """
  Emit an event onto the bus. `event` is a map; missing `:id`/`:at` are stamped. Opts:
    * `:depth`  — causation depth (loop guard); auto-incremented by the `emit` effect
    * `:tenant` — tenant scope, threaded into effect ctx
  Fans out to matching hooks (async) and live subscribers. Returns the stamped event.
  """
  def emit(event, opts \\ []) when is_map(event) do
    depth = Keyword.get(opts, :depth, Map.get(event, :depth, 0))
    tenant = Keyword.get(opts, :tenant, Map.get(event, :tenant))

    if depth > @max_depth do
      Logger.warning("[events] dropping event at depth #{depth} (loop guard): #{inspect(event[:kind])}")
      event
    else
      ev =
        event
        |> Map.put_new(:id, gen_id())
        |> Map.put_new(:at, System.os_time(:second))
        |> Map.put(:depth, depth)
        |> then(fn e -> if tenant, do: Map.put(e, :tenant, tenant), else: e end)

      ctx = %{depth: depth, tenant: tenant}
      dispatch_hooks(ev, ctx)
      broadcast(ev)
      ev
    end
  end

  # Run the effects of every hook whose match accepts this event — each effect in its own supervised
  # task (failure-isolated, non-blocking).
  defp dispatch_hooks(ev, ctx) do
    # Hook matching runs in the EMITTER's process — a bad hook/event must never crash the caller.
    matched = try do Nexus.Hook.matching(ev) rescue e -> Logger.error("[events] hook matching crashed: #{Exception.message(e)}"); [] end

    for hook <- matched, effect <- hook.effects do
      Task.Supervisor.start_child(@tasksup, fn ->
        try do
          Nexus.Effects.run(effect, ev, ctx)
        rescue
          e -> Logger.error("[events] effect #{effect[:name]} crashed: #{Exception.message(e)}")
        end
      end)
    end

    :ok
  end

  # ── live subscriptions (websocket / SSE tail) ──────────────────────────────────────────────────

  @doc """
  Subscribe the calling process to the bus. `filter` is `fn event -> boolean end` (default: all).
  The process receives `{:event, event}` messages. Used by the websocket/SSE tail.
  """
  def subscribe(filter \\ fn _ -> true end) when is_function(filter, 1) do
    {:ok, _} = Registry.register(@subs, @key, filter)
    :ok
  end

  defp broadcast(ev) do
    Registry.dispatch(@subs, @key, fn entries ->
      for {pid, filter} <- entries do
        ok? = try do filter.(ev) rescue _ -> false end
        if ok?, do: send(pid, {:event, ev})
      end
    end)
  end

  defp gen_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
