defmodule Workbooks.TelemetryBus do
  @moduledoc """
  Runtime telemetry firehose (wb-kbq5.5) — the `runtime:telemetry` channel. Every
  session event the desktop bridge translates is ALSO emitted here, wrapped in a
  `{session_id, event_type, ts, payload}` envelope, so a fleet/kanban view can
  show ALL sessions (not just the one chat panel it joined). A duplicate-key
  Registry of subscribed shells, mirroring DesktopControl.
  """
  @registry Workbooks.TelemetryBus.Registry
  @topic "runtime:telemetry"

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "A shell joined runtime:telemetry — remember it for the firehose."
  def register(join_ref) do
    Registry.unregister(@registry, :subs)
    Registry.register(@registry, :subs, join_ref)
  end

  @doc "Fan a session event out to every telemetry subscriber, enveloped."
  def emit(session_id, event_type, payload) do
    envelope = %{
      "session_id" => session_id,
      "event_type" => event_type,
      "ts" => System.system_time(:second),
      "payload" => payload
    }

    Registry.dispatch(@registry, :subs, fn entries ->
      for {pid, join_ref} <- entries do
        send(pid, {:channel_push, join_ref, @topic, "event", envelope})
      end
    end)

    :ok
  rescue
    _ -> :ok
  end
end
