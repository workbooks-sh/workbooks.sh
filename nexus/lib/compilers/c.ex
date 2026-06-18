defmodule Nexus.Compilers.C do
  @moduledoc """
  The C lane — clang.wasm (the LLVM multitool, run directly via wasmtime like the rust lane,
  NOT through any command registry) compiles C → a wasm reactor module exporting the unit's
  functions. Cleaner than rust: clang emits function-exports directly, so there's no mrustc
  whole-program-from-main quirk — just `clang -c` + `wasm-ld --no-entry --export=<fn>`.
  """
  import Nexus.Compilers.Shared, only: [wasmtime: 1]

  @doc "Compile a C source file to a wasm core module exporting `opts[:exports]`. `{:ok, path}`."
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

    exports = opts |> Keyword.get(:exports, []) |> Enum.map(&"--export=#{&1}")
    # host imports (extern decls) stay unresolved → wasm imports the Dock satisfies
    au = if Keyword.get(opts, :allow_undefined, false), do: ["--allow-undefined"], else: []
    cl.(["clang", "--target=wasm32-wasip1", "--sysroot=/usr", "-O1", "-w"] ++ cflags ++ ["-c", "/work/u.c", "-o", "/work/u.o"])
    cl.(["wasm-ld", "-m", "wasm32", "--no-entry"] ++ au ++ exports ++ ["/work/u.o", "-o", "/work/u.wasm"])

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
