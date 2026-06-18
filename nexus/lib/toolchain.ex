defmodule Nexus.Toolchain do
  @moduledoc """
  The ONE toolchain, on the server — the **same Zig `.work` parser the CLI uses**, compiled to an 8KB
  wasm reactor (`cli/src/lib.zig` → `work-toolchain.wasm`) and instantiated ONCE here. Calling it is
  faster than the old in-process Elixir parser (0.034ms vs 0.13ms — the Zig parser beats Elixir even
  through the Wasmex marshal) AND it's DRY: server and CLI share one implementation, conformance-gated
  so they can't diverge. This is the zero-drift north star, proven.

  A GenServer owns the reactor instance + serializes calls. `parse_units/1` returns the code units.
  """
  use GenServer

  @wasm Path.join(:code.priv_dir(:nexus), "work-toolchain.wasm")

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Parse `.work` source via the Zig reactor → `[%{name, kind, lang}]` (the code units)."
  def parse_units(src) when is_binary(src), do: GenServer.call(__MODULE__, {:parse_units, src})

  @doc "Parse `.work` source via the Zig reactor → the FULL nodes (type/kind/lang/name/header/body/refs)."
  def parse(src) when is_binary(src), do: GenServer.call(__MODULE__, {:parse_json, src})

  @doc "Whether the reactor wasm is present (so callers can fall back if not staged)."
  def available?, do: File.exists?(@wasm)

  @impl true
  def init(:ok) do
    {:ok, pid} = Wasmex.start_link(%{bytes: File.read!(@wasm)})
    {:ok, memory} = Wasmex.memory(pid)
    {:ok, store} = Wasmex.store(pid)
    {:ok, %{pid: pid, memory: memory, store: store}}
  end

  @impl true
  def handle_call({:parse_json, src}, _from, st) do
    json = invoke(st, "parse_json", src)
    {:reply, Jason.decode!(json), st}
  end

  def handle_call({:parse_units, src}, _from, %{pid: pid, memory: memory, store: store} = s) do
    out = invoke(%{pid: pid, memory: memory, store: store}, "parse_units", src)

    units =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [name, kind, lang] = String.split(line, "|", parts: 3)
        %{name: name, kind: kind, lang: lang}
      end)

    {:reply, units, s}
  end

  # Call a reactor export with a string in, string out (the pointer-len ABI). Serialized by the GenServer.
  defp invoke(%{pid: pid, memory: memory, store: store}, fun, src) do
    import Bitwise
    Wasmex.call_function(pid, "reset", [])
    {:ok, [ptr]} = Wasmex.call_function(pid, "alloc", [byte_size(src)])
    Wasmex.Memory.write_binary(store, memory, ptr, src)
    {:ok, [packed]} = Wasmex.call_function(pid, fun, [ptr, byte_size(src)])
    Wasmex.Memory.read_binary(store, memory, bsr(packed, 32), band(packed, 0xFFFFFFFF))
  end
end
