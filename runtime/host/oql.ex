defmodule Workbooks.OQL do
  @moduledoc """
  The Work kernel. Loads `oql.wasm` — a WIT-typed Component (the `workbooks:oql`
  world) — and reads `work-*` structure: query (parse_headlines), the WIT-world
  build plan (tangle_plan), validation, the upgrade gate, and render. One shared
  kernel; the same component the browser viewer and Package Manager use. The
  export names are stable; the front-end is the Work format. See
  docs/WORK-FORMAT.md.

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

  @doc "Parse Work → list of node maps (level, title, state, id, tags, props)."
  def parse_headlines(src) when is_binary(src), do: call_json("parse-headlines", [src])

  @doc "Lint Work → list of diagnostics."
  def lint(src) when is_binary(src), do: call_json("lint", [src])

  @doc "Emit the WIT-world-shaped build plan from a Work workbook."
  def tangle_plan(src) when is_binary(src), do: call_json("tangle-plan", [src])

  @doc "Validate a Work workbook → diagnostics (dangling inputs, missing language)."
  def validate(src) when is_binary(src), do: call_json("validate", [src])

  @doc "Gate an upgrade: diff a deployed Workbook vs a new one, refuse breaking changes."
  def check_upgrade(old, new) when is_binary(old) and is_binary(new),
    do: call_json("check-upgrade", [old, new])

  @doc "Render Work → `work-*` HTML (inside the kernel). Returns a raw string."
  def render(src) when is_binary(src), do: GenServer.call(__MODULE__, {:call, "render", [src]})

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
