defmodule Nexus.WashyPorfforBridgeTest do
  @moduledoc """
  **The Porffor↔host call bridge, end to end on the real Washy lane.**

  A Porffor-compiled program (with the `host_prelude.js` guest helpers) calls `__host_call` → the
  `Nexus.Compilers.Js.PorfforHost` handler reads/writes the running module's linear memory and dispatches.
  Proves: (1) bytes round-trip through guest memory as a real `Uint8Array`, and (2) the real target —
  `rollup_parse` routes through `Nexus.Washy.HostRollup` (the Rust parser as a sibling Washy module) and
  hands the flat AST buffer back to the guest. This is the parse seam a build tool needs to run on Porffor.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  setup_all do
    if File.regular?(Nexus.Compilers.Js.Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  defp run(body) do
    prog = Nexus.Compilers.Js.Porffor.host_prelude() <> "\n" <> body

    case Nexus.Compilers.Js.Porffor.eval(prog) do
      {:ok, out} -> {:ok, String.replace(out, ~r/\e\[[0-9;]*m/, "")}
      other -> other
    end
  end

  test "byte round-trip through guest memory as a Uint8Array (echo_upper)" do
    assert {:ok, out} =
             run("""
             const r = hostCall("echo_upper", "hello world");
             console.log(r.length); console.log(r[0]); console.log(r[1]);
             """)

    # "HELLO WORLD" — 11 bytes, 'H'=72, 'E'=69
    assert String.trim(out) |> String.split() == ["11", "72", "69"]
  end

  test "rollup_parse routes through HostRollup and returns the AST buffer to the guest" do
    assert {:ok, out} =
             run("""
             const ast = hostCall("rollup_parse", "const x = 1 + 2;");
             console.log(ast.length > 0 ? "GOT" : "EMPTY");
             """)

    assert String.trim(out) == "GOT"
  end
end
