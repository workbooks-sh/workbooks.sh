defmodule Nexus.WashyRealTest do
  @moduledoc """
  Washy running REAL clang-compiled C programs (our clang.wasm lane → wasm → Washy, pure Elixir,
  BEAM-isolated). Runs only when the C wasm lane is built; skips otherwise. This is the empirical driver
  that surfaces exactly which opcodes/WASI calls a real toolchain emits.
  """
  use ExUnit.Case, async: false

  defp compile(src) do
    p = Path.join(System.tmp_dir!(), "wreal#{System.unique_integer([:positive])}.c")
    File.write!(p, src)
    {:ok, wasm} = Nexus.Compilers.C.compile_to_wasm(p, shape: :command)
    {:ok, mod} = Nexus.Washy.decode(File.read!(wasm))
    mod
  end

  defp run(mod) do
    try do
      {_r, out} = Nexus.Washy.call_io(mod, "_start", [])
      {0, out}
    catch
      :throw, {:washy_exit, code} -> {code, Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  @tag timeout: 240_000
  test "a real clang-compiled C program runs end-to-end and returns its exit code" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      {code, _out} = run(compile("int main(void){ return 42; }"))
      assert code == 42
    else
      IO.puts("\n[skip] C wasm lane not built")
    end
  end
end
