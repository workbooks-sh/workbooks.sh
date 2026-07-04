defmodule Nexus.Toolchain do
  @moduledoc """
  The ONE toolchain, on the server — the **same Zig `.work` parser the CLI uses**, compiled to an 8KB
  wasm reactor (`cli/src/lib.zig` → `work-toolchain.wasm`) and instantiated ONCE here. It runs on
  `TinyLasers.Wasm` (wb-4z3fv — no wasmex): the reactor imports nothing (pure computation, no WASI), so
  it's a straight decode + a persistent transpiled instance whose hot exports JIT to BEAM assembly. DRY:
  server and CLI share one implementation, conformance-gated so they can't diverge — the zero-drift proof.

  A GenServer owns the reactor instance + serializes calls. `parse_units/1` returns the code units.
  """
  use GenServer
  alias TinyLasers.Wasm

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
    {:ok, mod} = Wasm.decode(File.read!(@wasm))
    # instantiate once (via a no-op `reset`) + turn on the transpiler so `parse_*` JIT across re-entries.
    {:ok, inst, _out} = Wasm.instance_start(mod, "reset", [], transpile: true)
    {:ok, %{inst: inst}}
  end

  @impl true
  def handle_call({:parse_json, src}, _from, st) do
    {json, inst} = invoke(st.inst, "parse_json", src)
    {:reply, Jason.decode!(json), %{st | inst: inst}}
  end

  def handle_call({:parse_units, src}, _from, st) do
    {out, inst} = invoke(st.inst, "parse_units", src)

    units =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [name, kind, lang] = String.split(line, "|", parts: 3)
        %{name: name, kind: kind, lang: lang}
      end)

    {:reply, units, %{st | inst: inst}}
  end

  # Call a reactor export with a string in, string out (the pointer-len ABI): reset the bump allocator,
  # alloc `len`, write the source into guest memory, invoke `fun` → packed `(ptr << 32) | len`, read the
  # result bytes back. Serialized by the GenServer; the (possibly grown) instance is threaded forward.
  defp invoke(inst, fun, src) do
    import Bitwise
    {:ok, _, _, inst} = Wasm.instance_invoke(inst, "reset", [])
    {:ok, ptr, _, inst} = Wasm.instance_invoke(inst, "alloc", [byte_size(src)])
    Wasm.write_bytes(inst.mem, ptr, src)
    {:ok, packed, _, inst} = Wasm.instance_invoke(inst, fun, [ptr, byte_size(src)])
    {Wasm.read_bytes(inst.mem, bsr(packed, 32), band(packed, 0xFFFFFFFF)), inst}
  end
end
