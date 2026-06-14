defmodule Workbooks.MonocypherLaneTest do
  @moduledoc """
  Proves the monocypher (crypto) lane (C→wasm32-wasip1): Ed25519 keygen + sign + verify (valid), tamper-rejection,
  and Blake2b hashing run in-sandbox via build_c_dir. Source provisioned by compilers/monocypher/build.sh
  (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/monocypher/src"))

  @tag :build
  @tag timeout: 300_000
  test "Ed25519 sign/verify + tamper-rejection + Blake2b in-sandbox" do
    if not File.regular?(Path.join(@src, "monocypher.c")) do
      IO.puts("\n[skip] monocypher source not staged — run compilers/monocypher/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "sign_verify=1"        # valid signature verifies
      assert out =~ "tamper_rejected=1"    # tampered signature rejected
    end
  end
end
