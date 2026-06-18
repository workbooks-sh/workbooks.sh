defmodule Nexus.Compilers.Zig do
  @moduledoc """
  The zig lane — zig compiles *to C* (`-ofmt=c`), so this runs `zig1.wasm` **directly** (like the
  rust/C lanes, NOT through the old command registry) to emit C, then hands that C to
  `Nexus.Compilers.C` with the zig lib on the include path (zig's output `#include`s `zig.h`).
  zig → C → wasm reactor. No command machinery.
  """
  import Nexus.Compilers.Shared, only: [wasmtime: 1]

  @doc "Compile a zig source file to a wasm core module exporting `opts[:exports]`. `{:ok, path}`."
  def compile_to_wasm(source_path, opts \\ [], root \\ Nexus.Compilers.Shared.default_root()) do
    base = Path.expand(Path.join([root, "zig", "zig-root"]))
    zig1 = Path.join([base, "stage1", "zig1.wasm"])
    ziglib = Path.join(base, "lib")
    id = "nx_#{System.unique_integer([:positive])}"
    job = Path.join(base, "jobs/#{id}")
    rel = "jobs/#{id}"
    File.mkdir_p!(Path.join(job, "zc"))
    File.mkdir_p!(Path.join(job, "gc"))
    File.cp!(Path.expand(source_path), Path.join(job, "src.zig"))

    wasmtime([
      "--dir", "#{base}::.", zig1, "build-obj", "-ofmt=c", "-OReleaseSmall",
      "--zig-lib-dir", "lib", "--cache-dir", "#{rel}/zc", "--global-cache-dir", "#{rel}/gc",
      "--name", "out", "-femit-bin=#{rel}/out.c", "-target", "wasm32-wasi", "-Mroot=#{rel}/src.zig"
    ])

    outc = Path.join(job, "out.c")

    result =
      if File.regular?(outc) and File.stat!(outc).size > 0 do
        Nexus.Compilers.C.compile_to_wasm(outc, Keyword.merge(opts, extra_dirs: ["#{ziglib}::/ziglib"], cflags: ["-I/ziglib"]))
      else
        {:error, :zig_compile_failed}
      end

    File.rm_rf(job)
    result
  end
end
