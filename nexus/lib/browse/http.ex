defmodule Nexus.Browse.Http do
  @moduledoc """
  The light browse provider — a host-brokered HTTP GET (SSRF-safe) via `Nexus.Dock.fetch`. Capability
  `:fetch` only; the in-wasm Blitz provider adds `:render`/`:screenshot`. The default that's always
  present.
  """
  @behaviour Nexus.Browse

  @impl true
  def capabilities, do: [:fetch]

  @impl true
  def fetch(url, _opts) do
    case Nexus.Dock.fetch(url) do
      "" -> {:error, :empty_or_blocked}
      body -> {:ok, body}
    end
  end
end
