defmodule Nexus.AuthorshipInteropTest do
  @moduledoc """
  Cross-stack proof: a real WebCrypto Ed25519 key (the SAME path the browser/StarlingMonkey runs) is
  decoded + verified by the Elixir side. Guards the browser→server proof-of-possession contract so a
  drift in either the did:key encoding or the signing message breaks the build, not production.

  Runs the headless JS mirror (test/interop/device_key.mjs) via Node's WebCrypto. Skips cleanly if Node
  (or its Ed25519 support) is unavailable, so it never blocks a machine without the JS toolchain.
  """
  use ExUnit.Case, async: true
  alias Nexus.{Authorship, Keyring}

  @script Path.join([__DIR__, "interop", "device_key.mjs"])

  setup_all do
    case node_ed25519?() do
      true -> :ok
      false -> {:ok, skip: true}
    end
  end

  test "browser WebCrypto key registers + verifies against the Elixir authorship core", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] Node WebCrypto Ed25519 unavailable — browser interop not exercised")
    else
      {out, 0} = System.cmd("node", [@script, "shane@x.com"], stderr_to_stdout: true)
      [uid, did, sig] = out |> String.trim() |> String.split("\n") |> Enum.take(-3)

      # the JS-built did:key is the canonical W3C/Radicle ed25519 form and decodes to a 32-byte key
      assert String.starts_with?(did, "did:key:z6Mk")
      assert {:ok, pub} = Keyring.public_from_did(did)
      assert byte_size(pub) == 32

      # the WebCrypto signature over the registration message verifies on the Elixir side
      assert Authorship.verify_registration(uid, did, sig)
      # ...and is bound to its uid (no cross-account replay)
      refute Authorship.verify_registration("evil@x.com", did, sig)
    end
  end

  defp node_ed25519? do
    case System.cmd("node", ["-e", "crypto.subtle.generateKey({name:'Ed25519'},true,['sign','verify']).then(()=>process.exit(0)).catch(()=>process.exit(1))"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
