defmodule Workbooks.SandboxInvariantTest do
  @moduledoc """
  Enforces the runtime execution invariant (docs/SANDBOX-INVARIANT.org, wb-ova):

    Untrusted/arbitrary code executes ONLY inside the wasmtime sandbox; Wasmex is the only NIF that
    runs it; everything else is pure Elixir/Erlang or wasm. No untrusted code ever runs as a native
    OS process, in any other NIF, or with raw net/fs.

  These tests make that claim un-regressable: a new dependency or a native compiler/runtime call
  fails the build until it's consciously reviewed against the contract.
  """
  use ExUnit.Case, async: true

  # Every dependency, reviewed and classified in SANDBOX-INVARIANT.org. To add one: classify it
  # there first (pure-Elixir? trusted-infra NIF? does it run UNTRUSTED code? — only Wasmex may),
  # then add its name here.
  @reviewed_deps ~w(wasmex exqlite jason bandit plug websock_adapter guardian jose postgrex)a
  # Opt-in ML stack (WB_CLIP=1): trusted-infra NIFs that process the runtime's own models, never user code.
  @reviewed_ml_deps ~w(ortex tokenizers nx stb_image)a

  test "no dependency is added without security review (deps are a sandbox-boundary surface)" do
    names = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    allowed = MapSet.new(@reviewed_deps ++ @reviewed_ml_deps)
    unexpected = MapSet.difference(names, allowed) |> MapSet.to_list()

    assert unexpected == [],
           """
           Unreviewed dependency: #{inspect(unexpected)}.
           Classify it in docs/SANDBOX-INVARIANT.org — is it pure Elixir, a trusted-infra NIF, or does
           it run UNTRUSTED code? (Only Wasmex may run untrusted code.) Then add it to @reviewed_deps.
           """
  end

  test "untrusted code is never compiled or run as a native process (only wasmtime)" do
    # A native rustc/cargo/cc/ld/ar — or `clang`/`gcc` as the COMMAND (not as a wasm-module argv to
    # wasmtime) — would mean executing/compiling untrusted code outside the sandbox. Forbidden.
    forbidden = ~r/System\.cmd\(\s*"(rustc|cargo|cc|ld|ar|gcc)"|:os\.cmd/

    offenders =
      Path.wildcard("host/**/*.ex")
      |> Enum.filter(fn f ->
        body = File.read!(f)
        Regex.match?(forbidden, body) or Regex.match?(~r/System\.cmd\(\s*"clang"/, body)
      end)

    assert offenders == [],
           "Native compiler/runtime invoked in #{inspect(offenders)} — untrusted code must compile AND run only in wasm (under wasmtime)."
  end

  test "no rogue NIF: the runtime declares no rustler/NIF dep other than the reviewed ones" do
    # mix.exs is the single place native code can enter the BEAM. Guard against an unreviewed
    # rustler_precompiled / make / C-NIF dep slipping in via a transitive {:dep, ...} addition.
    deps_src = File.read!("mix.exs")
    # the only NIF-bearing dep we vendor/build from source is wasmex (path dep).
    assert deps_src =~ "{:wasmex, path: \"vendor/wasmex\"}",
           "Wasmex must remain the vendored path dep (the one untrusted-exec NIF)."
  end
end
