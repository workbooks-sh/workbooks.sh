defmodule Nexus.Overlay do
  @moduledoc """
  §10 — the reality overlay. The static graph (§9) is pure and derived-fresh: it
  holds only what the author wrote. But a unit also has *realities* the author
  never wrote — the live DB schema behind a `resource`, the runtime telemetry of an
  agent. Those are high-volume, mutable, time-series; they must not pollute the
  pure build. So they live here, in a separate store keyed by the canonical
  identity (§1, `Uid.key`), and are joined onto the graph at query time via
  `Nexus.Graph.with_overlay/2`.

  This is the seam that lets the graph cover code, data, and execution under one
  identity without any new authoring syntax — `data`/`observed` are *read back*,
  never declared.
  """

  defstruct data: %{}, observed: %{}

  @type t :: %__MODULE__{data: map, observed: map}

  alias Nexus.Uid

  @doc "An empty overlay."
  def new, do: %__MODULE__{}

  @doc "Attach a data-reality facet (e.g. an ingested DB schema) for a unit, keyed by Uid."
  def put_data(%__MODULE__{data: d} = ov, unit, facet),
    do: %{ov | data: Map.put(d, Uid.key(unit), facet)}

  @doc "Attach an execution-reality facet (e.g. drained telemetry) for a unit, keyed by Uid."
  def put_observed(%__MODULE__{observed: o} = ov, unit, facet),
    do: %{ov | observed: Map.put(o, Uid.key(unit), facet)}

  @doc "The data facet recorded for a unit, or nil."
  def data(%__MODULE__{data: d}, unit), do: Map.get(d, Uid.key(unit))

  @doc "The observed facet recorded for a unit, or nil."
  def observed(%__MODULE__{observed: o}, unit), do: Map.get(o, Uid.key(unit))

  @doc "Merge two overlays (right wins on key collisions)."
  def merge(%__MODULE__{} = a, %__MODULE__{} = b),
    do: %__MODULE__{data: Map.merge(a.data, b.data), observed: Map.merge(a.observed, b.observed)}
end
