defmodule Nexus.Wit do
  @moduledoc """
  Generate the WIT contract from a unit — `record`/`enum`/`variant` from the shape, typed `func`
  signatures, `import`s from grants. The wire interface for every connection; never hand-written.

  STATUS: **port** from `runtime/host/wit.ex` (+ `wit/types.ex`) — built & tested.
  """
  def world(_node), do: raise("port from runtime/host/wit.ex")
end
