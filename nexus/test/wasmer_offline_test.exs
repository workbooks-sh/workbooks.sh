defmodule Nexus.WasmerOfflineTest do
  @moduledoc """
  TRUE airgap (Phase 2 / wb-hhhp): the self-contained bundles run with NO registry access. The prebuilt
  `sharrattj/bash` declares a `wasmer/coreutils` dep that wasmer always re-resolves online; our bundle
  strips it, so bash + coreutils + python run under an UNREACHABLE registry. Needs wasmer + a one-time
  download to build the bundle; skips otherwise.
  """
  use ExUnit.Case, async: false

  @moduletag :wasmer

  test "bash_pkg resolves to a LOCAL bundle, not a registry name" do
    if Nexus.Wasmer.available?() do
      pkg = Nexus.Wasmer.bash_pkg()
      # a bundle is an absolute path to a .webc; the registry fallback is "sharrattj/bash@…"
      assert String.ends_with?(pkg, ".webc"), "expected a local bundle, got #{pkg}"
      assert File.exists?(pkg)
    else
      IO.puts("\n[skip] wasmer absent")
    end
  end

  test "the bundle runs bash + coreutils in a pipe under an UNREACHABLE registry (airgap)" do
    if Nexus.Wasmer.available?() and is_binary(Nexus.Wasmer.bash_bundle()) do
      bundle = Nexus.Wasmer.bash_bundle()
      coreutils = Nexus.Wasmer.coreutils()

      # Run wasmer DIRECTLY with a dead registry — if anything still needed the registry, this errors.
      args = ["run", bundle, "--use", coreutils, "--", "-c", "printf 'b\\na\\nc\\n' | sort | tr a-z A-Z"]
      {out, _} = System.cmd(Nexus.Wasmer.bin(), args, env: [{"WASMER_REGISTRY", "https://invalid.invalid"}], stderr_to_stdout: true)

      refute out =~ "Unable to find"
      refute out =~ "registry"
      assert out =~ "A" and out =~ "B" and out =~ "C"
    else
      IO.puts("\n[skip] wasmer or bundle absent")
    end
  end
end
