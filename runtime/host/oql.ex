defmodule Workbooks.OQL do
  @moduledoc """
  The Org kernel. Loads `oql.wasm` — a WIT-typed Component (the `workbooks:oql`
  world) — and reads Org structure: query (parse_headlines), the WIT-world build
  plan (tangle_plan), validation, the upgrade gate, and render. One shared
  kernel; the same component the browser viewer and Package Manager use.

  The kernel rides the Component Model it imposes on user code: every export is
  string→string, called through `Wasmex.Components` — no hand-rolled ptr/len
  ABI, no manual memory bookkeeping. Pure compute, so it needs no WASI context;
  a fault traps inside Wasmtime rather than touching the host.
  """
  use GenServer

  # Embed the component at compile time — the app carries no runtime asset
  # folder. Built from kernel/ (cargo component build) into build/oql.wasm.
  @wasm_path Path.expand(Path.join([__DIR__, "..", "build", "oql.wasm"]))
  @external_resource @wasm_path
  @oql_wasm File.read!(@wasm_path)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Parse Org → list of headline maps (level, title, state, id, tags, props)."
  def parse_headlines(org) when is_binary(org), do: call_json("parse-headlines", [org])

  @doc "Lint Org → list of diagnostics."
  def lint(org) when is_binary(org), do: call_json("lint", [org])

  @doc "Emit the WIT-world-shaped build plan from a literate Workbook."
  def tangle_plan(org) when is_binary(org), do: call_json("tangle-plan", [org])

  @doc "Validate a literate Workbook → diagnostics (dangling inputs, missing language)."
  def validate(org) when is_binary(org), do: call_json("validate", [org])

  @doc "Gate an upgrade: diff a deployed Workbook vs a new one, refuse breaking changes."
  def check_upgrade(old, new) when is_binary(old) and is_binary(new),
    do: call_json("check-upgrade", [old, new])

  @doc "Render Org → rich HTML (orgize, inside the kernel). Returns a raw string."
  def render(org) when is_binary(org), do: GenServer.call(__MODULE__, {:call, "render", [org]})

  defp call_json(fun, args), do: GenServer.call(__MODULE__, {:call_json, fun, args})

  @impl true
  def init(_) do
    {:ok, pid} = Wasmex.Components.start_link(%{bytes: @oql_wasm})
    {:ok, %{pid: pid}}
  end

  @impl true
  def handle_call({:call_json, fun, args}, _from, %{pid: pid} = s),
    do: {:reply, Jason.decode!(call!(pid, fun, args)), s}

  def handle_call({:call, fun, args}, _from, %{pid: pid} = s),
    do: {:reply, call!(pid, fun, args), s}

  # Typed Component call: args in, a string out — no memory protocol.
  defp call!(pid, fun, args) do
    {:ok, result} = Wasmex.Components.call_function(pid, fun, args)
    result
  end
end
