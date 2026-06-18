defmodule Nexus.Resource do
  @moduledoc """
  A `resource`/`record` unit's DECLARED domain-typed fields (`:text`, `:money`, inline enum,
  `[:text]`) → the shape. No inference. The single source the WIT, the struct, and Ash all derive.

  STATUS: **port** from `runtime/host/resource.ex` (+ `resource/ash.ex`) — built & tested.
  """
  def fields(_node), do: raise("port from runtime/host/resource.ex")
end
