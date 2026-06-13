defmodule Workbooks.Reclaim.CargoTest do
  @moduledoc """
  RECLAIM: Cargo — its CORE capability (resolve a crates.io dependency from the sparse index +
  fetch the .crate + transitive-dep resolution + mrustc→clang compile + link, all in-sandbox,
  zero native toolchain) is reproduced here by driving Workbooks.Compilers.rust_compile_to_wasm/2
  with `deps:` and then running the produced wasm via Workbooks.PackageManager.run/3.

  HONEST SCOPE: this is Cargo's resolve+fetch+build for pure-Rust crates — NOT cargo's build.rs
  native-build or thread/async-runtime support (documented limits). The two cases below cover:
    * fnv@1.0.7        — a real leaf crate (the recipe's flagship proof).
    * num-integer@0.1.45 — a TRANSITIVE crate that pulls num-traits; proves the sparse-index
      resolution + transitive dependency walk + fetch of MULTIPLE crates, which is the part that
      makes this "Cargo" rather than "compile one file".

  Each case actually RUNS the linked wasm and asserts on its stdout, so it proves the crate's code
  executed in-sandbox, not merely that resolution succeeded.

  @tag :netdeps (fetches from static.crates.io / index.crates.io) and @tag :build (full compile).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Compilers
  alias Workbooks.PackageManager, as: PM

  defp build_run(src, deps, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "reclaim_cargo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "main.rs")
    File.write!(path, src)

    try do
      Compilers.rust_compile_to_wasm(path, Keyword.merge([deps: deps], opts))
    after
      File.rm_rf(dir)
    end
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 900_000
  test "fnv@1.0.7 — resolve+fetch+build a real crates.io leaf crate, then run it" do
    src = ~S"""
    use std::hash::Hasher;
    fn main() {
        let mut h = fnv::FnvHasher::default();
        h.write(b"hello");
        println!("{}", h.finish());
    }
    """

    case build_run(src, [{"fnv", "1.0.7"}]) do
      {:ok, wasm, _logs} ->
        out = PM.run(wasm, "", []) |> String.trim()
        # FNV-1a 64-bit of "hello" is a fixed value; assert it's the known digest, not just non-empty.
        assert out == "11831194018420276491",
               "fnv produced #{inspect(out)} — expected the FNV-1a-64 digest of \"hello\""

      {:error, reason} ->
        flunk("rust_compile_to_wasm with fnv dep failed: #{inspect(reason)}")
    end
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 1_200_000
  test "num-integer@0.1.45 — TRANSITIVE resolve (pulls num-traits) + build + run" do
    src = ~S"""
    fn main() {
        // num_integer::gcd exercises code that depends on the transitively-fetched num-traits crate.
        println!("{}", num_integer::gcd(48u32, 36u32));
        println!("{}", num_integer::lcm(4u32, 6u32));
    }
    """

    case build_run(src, [{"num-integer", "0.1.45"}]) do
      {:ok, wasm, _logs} ->
        out = PM.run(wasm, "", []) |> String.trim()
        assert out == "12\n12" or out == "12\r\n12",
               "num-integer produced #{inspect(out)} — expected gcd(48,36)=12 and lcm(4,6)=12"

      {:error, reason} ->
        flunk("rust_compile_to_wasm with transitive num-integer dep failed: #{inspect(reason)}")
    end
  end
end
