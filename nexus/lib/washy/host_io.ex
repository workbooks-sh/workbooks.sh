defmodule Nexus.Washy.HostIO do
  @moduledoc """
  The **host-import delegation seam** for per-concern I/O modules — the Wave-0 mechanism that makes the
  Elixir host side fan-out-shaped (so parallel agents never collide on `washy.ex`).

  A guest host import whose name is `<concern>_<op>` (e.g. `fs_read_file`, `net_connect`, `crypto_hash`)
  is routed by `Nexus.Washy`'s catch-all `call_host` clause to `dispatch/2`, which resolves the concern
  to a module **by convention** — prefix `fs` → `Nexus.Washy.HostFs`, `net` → `HostNet`, `crypto` →
  `HostCrypto`, etc. — and calls its `handle(name, args)`. There is **no central registry to edit**: an
  agent adds a concern purely by creating `lib/washy/host_<concern>.ex` with a `handle/2`. Integration is
  conflict-free because each concern is its own file.

  ## Writing a concern module

      defmodule Nexus.Washy.HostFs do
        # Each clause handles one import; read/write guest linear memory via the helpers below.
        # Return the i32 the guest's C wrapper expects (length written, status, fd, …).
        def handle("fs_read_file", [path_ptr, path_len, out_ptr]) do
          path = HostIO.read(path_ptr, path_len)
          case Nexus.Washy.VFS.get(path) do
            {:ok, bytes} -> HostIO.write(out_ptr, bytes); byte_size(bytes)
            _ -> -1
          end
        end
      end

  Memory access (`read/2`, `write/2`) goes through the same `:washy_mem` process-dict slot every other
  host import uses, so a concern module needs no plumbing — just the guest pointers from `args`.
  """

  @doc "Read `len` bytes of guest linear memory at byte-offset `ptr`."
  def read(ptr, len), do: Nexus.Washy.read_bytes(mem(), ptr, len)

  @doc "Write `bin` into guest linear memory at byte-offset `ptr`. Returns `byte_size(bin)`."
  def write(ptr, bin) do
    Nexus.Washy.write_bytes(mem(), ptr, bin)
    byte_size(bin)
  end

  @doc "The guest's current linear memory (the active run/instance), from the process dict."
  def mem, do: Process.get(:washy_mem)

  @doc """
  Resolve a `<concern>_<op>` host-import name to its concern module by convention and invoke `handle/2`.
  Returns the handler's value, or `:no_host_module` when no matching concern module exists (the caller
  then treats the import as unimplemented).
  """
  def dispatch(name, args) when is_binary(name) do
    case String.split(name, "_", parts: 2) do
      [concern, _op] when concern != "" ->
        mod = Module.concat(Nexus.Washy, "Host" <> String.capitalize(concern))

        if Code.ensure_loaded?(mod) and function_exported?(mod, :handle, 2),
          do: mod.handle(name, args),
          else: :no_host_module

      _ ->
        :no_host_module
    end
  end
end
