defmodule Nexus.Wasm.Oracle do
  @moduledoc """
  The **differential oracle** for Washy. It runs a decoded module through every registered execution
  *backend* and reports whether they agree — the safety net that makes the wasm→BEAM transpiler
  trustworthy: a function is "correct" iff the transpiled output produces the *same observable outcome*
  (value, trap reason, or exit code) as the reference interpreter, on the same inputs.

  Outcomes are classified into a single comparable term so the two backends can be `==`'d directly:

    * `{:value, v}` — normal return
    * `{:trap, reason}` — a `TinyLasers.Wasm.Trap` (e.g. `:div_by_zero`, `:out_of_bounds`)
    * `{:exit, code}` — guest called `proc_exit`
    * `{:error, kind}` — an unexpected host/interp failure (NOT a wasm-level outcome)

  Backends (`backends/0`): `:interp` today. `:transpile` is added the moment the wasm→BEAM backend
  exists — then `compare/4` over `[:interp, :transpile]` is the conformance assertion, and every
  existing interpreter test (add/dbl/sumto, the trap suite, real C/Rust) becomes a transpiler test
  for free.
  """
  alias TinyLasers.Wasm, as: Washy
  alias TinyLasers.Wasm.Trap

  @backends [:interp]

  @doc "The execution backends the oracle knows about (`:transpile` joins when it lands)."
  def backends, do: @backends

  @doc """
  Run `fun(args)` on one backend, classifying the outcome into a comparable term
  (`{:value, _} | {:trap, _} | {:exit, _} | {:error, _}`).
  """
  def run(:interp, mod, fun, args) do
    classify(fn -> Washy.call(mod, fun, args) end)
  end

  # The wasm→BEAM transpiler (spike v0): compile to native, run, classify. `{:error, {:unsupported,
  # _}}` means the function is outside v0 scope — the test should skip the comparison, not fail.
  def run(:transpile, mod, fun, args) do
    case TinyLasers.Wasm.Transpile.compile(mod, fun) do
      {:ok, f} -> classify(fn -> f.(args) end)
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify(thunk) do
    {:value, thunk.()}
  rescue
    e in Trap -> {:trap, e.reason}
    e -> {:error, Exception.message(e)}
  catch
    :throw, {:tl_exit, code} -> {:exit, code}
  end

  @doc """
  Run `fun(args)` on every backend in `backends` and compare. Returns `{:agree, outcome}` when all
  backends produce the identical classified outcome, else `{:disagree, %{backend => outcome}}`.
  With a single backend this always agrees — but it still exercises the classifier and locks the
  contract, so adding `:transpile` turns it differential with no test changes.
  """
  def compare(mod, fun, args, backends \\ @backends) do
    results = Map.new(backends, fn b -> {b, run(b, mod, fun, args)} end)

    case results |> Map.values() |> Enum.uniq() do
      [one] -> {:agree, one}
      _ -> {:disagree, results}
    end
  end

  @doc """
  Assert all backends agree on `fun(args)`; returns the agreed outcome or raises with the divergence.
  The one call a transpiler test makes: `Oracle.assert_same(mod, "f", [3, 4])`.
  """
  def assert_same(mod, fun, args, backends \\ @backends) do
    case compare(mod, fun, args, backends) do
      {:agree, outcome} ->
        outcome

      {:disagree, results} ->
        raise "washy oracle: backends diverged on #{fun}(#{inspect(args)}):\n" <>
                Enum.map_join(results, "\n", fn {b, o} -> "  #{b}: #{inspect(o)}" end)
    end
  end
end
