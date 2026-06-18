defmodule Nexus.Compilers.C do
  @moduledoc """
  The C lane — clang.wasm (the LLVM multitool, run directly via wasmtime like the rust lane,
  NOT through any command registry). Two output shapes:

    * `:reactor` (default) — `wasm-ld --no-entry --export=<fn>` → a module exporting functions, for
      the resource/render component model.
    * `:command` — `wasm-ld <crt1-command.o>` → a `wasm32-wasi` COMMAND module (a `main()` CLI that
      reads argv/stdin, writes stdout). This is the **toolkit** shape — what `coreutils.wasm` is and
      what the agent's `bash` runs (`wasmtime run <wasm> argv < stdin`). It's how you author a kit
      in a `.work` file (`toolkit :name do <a main() CLI> end`).
  """
  import Nexus.Compilers.Shared, only: [wasmtime: 1]

  @doc """
  Compile a C source file to wasm. `opts[:shape]` is `:reactor` (default; exports `opts[:exports]`)
  or `:command` (a WASI CLI module — a toolkit). `{:ok, path}`.
  """
  def compile_to_wasm(source_path, opts \\ [], root \\ Nexus.Compilers.Shared.default_root()) do
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    work = Path.join(System.tmp_dir!(), "nxc_c_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(work, "t"))
    File.cp!(Path.expand(source_path), Path.join(work, "u.c"))

    # extra_dirs: host::guest mounts (e.g. the zig lib for zig.h); cflags: extra clang flags
    # (e.g. -I/ziglib). Lets the zig lane reuse this lane to compile zig's C-backend output.
    extra_mounts = opts |> Keyword.get(:extra_dirs, []) |> Enum.flat_map(&["--dir", &1])
    cflags = Keyword.get(opts, :cflags, [])

    cl = fn args ->
      wasmtime(["--dir", "#{csys}::/usr", "--dir", "#{work}::/work", "--dir", "#{work}/t::/tmp"] ++ extra_mounts ++ ["--env", "TMPDIR=/tmp", clang | args])
    end

    cl.(["clang", "--target=wasm32-wasip1", "--sysroot=/usr", "-O1", "-w"] ++ cflags ++ ["-c", "/work/u.c", "-o", "/work/u.o"])

    link =
      case Keyword.get(opts, :shape, :reactor) do
        :command ->
          # a WASI command module: the crt1 entry runs main(); link libc. No --no-entry/--export.
          ["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-wasip1",
           "/usr/lib/wasm32-wasip1/crt1-command.o", "/work/u.o", "-lc", "-o", "/work/u.wasm"]

        _ ->
          exports = opts |> Keyword.get(:exports, []) |> Enum.map(&"--export=#{&1}")
          au = if Keyword.get(opts, :allow_undefined, false), do: ["--allow-undefined"], else: []
          ["wasm-ld", "-m", "wasm32", "--no-entry"] ++ au ++ exports ++ ["/work/u.o", "-o", "/work/u.wasm"]
      end

    cl.(link)

    core = Path.join(work, "u.wasm")
    if File.regular?(core) do
      dest = Path.join(System.tmp_dir!(), "nxc_c_#{System.unique_integer([:positive])}.wasm")
      File.cp!(core, dest)
      File.rm_rf(work)
      {:ok, dest}
    else
      File.rm_rf(work)
      {:error, :c_compile_failed}
    end
  end
end
