defmodule Nexus.Browse do
  @moduledoc """
  The web-access seam for agents — a pluggable provider registry (like `Nexus.Langs` / `Nexus.Store`),
  migrated from the runtime's `Workbooks.Browse`. The architecture is settled: a real browser cannot
  run in wasm's JIT-less sandbox, so web access is **host-brokered** — but the goal is to keep as much
  as possible IN wasmtime (no bundled Chromium, no host-native browser).

  Capabilities a provider may implement:

    * `:fetch`      — raw HTTP GET of a URL → body (host-brokered, SSRF-safe). The light default.
    * `:render`     — HTML → **rendered** text/DOM via an in-wasm engine (Blitz: Stylo CSS + layout),
                      no JS. Runs in wasmtime, no native code.
    * `:screenshot` — HTML → a PNG (in-wasm Blitz paint via Vello-CPU).
    * `:search`     — a query → ranked results (a keyed search API, host-brokered).

  A provider declares its `capabilities/0` and implements those callbacks. `Nexus.Browse` routes each
  call to the first registered provider that supports it. The agent's `bash` (`fetch`/`scrape`/
  `render`/`screenshot`/`search`) calls through here.
  """

  @type url :: String.t()

  @callback capabilities() :: [:fetch | :render | :screenshot | :search]
  @callback fetch(url, keyword) :: {:ok, binary} | {:error, term}
  @callback render(html :: binary, keyword) :: {:ok, binary} | {:error, term}
  @callback screenshot(html :: binary, keyword) :: {:ok, binary} | {:error, term}
  @callback search(query :: String.t(), keyword) :: {:ok, [map]} | {:error, term}

  @optional_callbacks fetch: 2, render: 2, screenshot: 2, search: 2

  @builtin [Nexus.Browse.Http]
  @reg {:nexus_browse, :providers}

  @doc "All providers (built-in + registered)."
  def providers, do: @builtin ++ :persistent_term.get(@reg, [])

  @doc "Register a custom browse provider (e.g. a search backend, an in-wasm render engine)."
  def register(mod) do
    :persistent_term.put(@reg, Enum.uniq([mod | :persistent_term.get(@reg, [])]))
    :ok
  end

  def clear_registered, do: :persistent_term.put(@reg, [])

  @doc "The provider for a capability (first that supports it), or nil."
  def provider(cap), do: Enum.find(providers(), &(cap in &1.capabilities()))

  @doc "All capabilities any registered provider supports."
  def capabilities, do: providers() |> Enum.flat_map(& &1.capabilities()) |> Enum.uniq()

  # ── the routed API the agent's bash uses ───────────────────────────────────

  @doc "Raw HTTP GET → body."
  def fetch(url, opts \\ []), do: route(:fetch, [url, opts])

  @doc "Render HTML to readable text (in-wasm, CSS-aware, no JS)."
  def render(html, opts \\ []), do: route(:render, [html, opts])

  @doc "Render HTML to a PNG screenshot (in-wasm)."
  def screenshot(html, opts \\ []), do: route(:screenshot, [html, opts])

  @doc "Web search → ranked results."
  def search(query, opts \\ []), do: route(:search, [query, opts])

  defp route(cap, args) do
    case provider(cap) do
      nil -> {:error, {:no_provider, cap}}
      mod -> apply(mod, cap, args)
    end
  end
end
