defmodule Nexus.Compilers.Python do
  @moduledoc """
  The Python lane — an interpreter-in-wasm, mirroring the Go/yaegi precedent (`compilers/go`): a
  prebuilt `pythonrun.wasm` (RustPython, `wasm32-wasip1`) evals the user's Python read on stdin
  (stdin→stdout command shape, like the JS lane). The user source is fed at run time, so a `python`
  unit's artifact is the SAME `pythonrun.wasm` parameterized by stdin — there is nothing per-program
  to compile.

  The interpreter binary is a staged toolchain artifact (`compilers/python/pythonrun.wasm`), built
  once by `compilers/python/build.sh`. Until it is present, this lane returns a LOUD, explicit error
  — never a silent fake artifact.
  """

  @doc """
  Resolve the Python lane's artifact for a unit. Returns `{:ok, path}` to the interpreter wasm (the
  unit's source is supplied on stdin at run time), or `{:error, {:python_toolchain_missing, path}}`
  if the interpreter has not been built/staged yet.
  """
  def python_compile_to_wasm(_source, _opts \\ [], root \\ Nexus.Compilers.Shared.default_root()) do
    interp = Path.expand(Path.join([root, "python", "pythonrun.wasm"]))

    if File.regular?(interp) do
      {:ok, interp}
    else
      {:error, {:python_toolchain_missing, interp}}
    end
  end
end
