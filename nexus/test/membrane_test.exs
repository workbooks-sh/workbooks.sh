defmodule Nexus.MembraneTest do
  @moduledoc """
  The Membrane (wb-g5w3) — host caps resolve through ONE bus, and the socket-transport core dispatches
  IDENTICALLY to the agent's first-word path. Proves the seam without needing a real socket or wasmer:
  `handle_request/3` decodes a wire frame and routes through the same `Bash.host_dispatch/5`.
  """
  use ExUnit.Case, async: true
  alias Nexus.{Membrane, Agent.Bash, Agent.Vfs}

  setup do
    dir = Path.join(System.tmp_dir!(), "wb-mem-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "x.work"), "A unit.\n\nserver :x do\n  def f, do: :ok\nend\n")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, vfs: Vfs.attach(dir), dir: dir}
  end

  @perms %{grant: ["fs", "exec"]}

  describe "host_command? — the host-cap classification both transports share" do
    test "host caps are host; real programs are not" do
      for c <- ~w(work agent request fetch image video speak), do: assert Membrane.host_command?(c)
      for c <- ~w(ls cat sort grep python true), do: refute Membrane.host_command?(c)
    end
  end

  describe "socket transport == first-word transport (the unification)" do
    test "`work help` yields the SAME output via Bash.run and via Membrane.handle_request", %{vfs: vfs} do
      # `work help` is deterministic + side-effect-free (unlike `work check`, which compiles the unit and
      # so isn't idempotent across the shared BEAM) — the right probe for transport-equality.
      first_word = Bash.run(vfs, "work help", @perms) |> String.trim()
      via_socket = Membrane.handle_request(vfs, @perms, "work\thelp\n") |> String.trim()

      assert first_word =~ "compile + analyze"
      assert via_socket == first_word
    end

    test "a non-host command is refused by the bridge (real programs run in the shell)", %{vfs: vfs} do
      assert Membrane.handle_request(vfs, @perms, "ls\t-la\n") =~ "not a host capability"
    end
  end

  describe "wire-frame parsing" do
    test "splits cmd/args/stdin on the first tab/newline; tolerates missing stdin" do
      assert {"work", ["parse", "x.work"], "payload"} = Membrane.parse_frame("work\tparse\tx.work\npayload")
      assert {"work", ["check"], ""} = Membrane.parse_frame("work\tcheck\n")
      assert {"work", [], ""} = Membrane.parse_frame("work")
      assert {"", [], ""} = Membrane.parse_frame("")
    end
  end
end
