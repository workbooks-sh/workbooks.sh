defmodule Nexus.MembraneBridgeTest do
  @moduledoc """
  Phase 5 increment 2 END TO END (wb-g5w3): with a per-run Membrane socket active, a host cap is a real
  command bash can `exec` MID-PIPE — `echo x | work help` runs `work` through the guest shim → socket →
  the SAME dispatch as the first-word path. Needs wasmer (the guest shell); skips otherwise.
  """
  use ExUnit.Case, async: false
  alias Nexus.{Agent.Vfs, Agent.Bash, Membrane.Server}

  @moduletag :wasmer

  setup do
    if Nexus.Wasmer.available?() do
      dir = Path.join(System.tmp_dir!(), "wb-br-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "x.work"), "A unit.\n\nserver :x do\n  def f, do: :ok\nend\n")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, vfs: Vfs.attach(dir), dir: dir}
    else
      {:ok, skip: true}
    end
  end

  test "a host cap composes mid-pipe via the socket bridge", %{} = ctx do
    if ctx[:skip], do: IO.puts("\n[skip] wasmer absent"), else: (
      {:ok, srv} = Server.start_link(ctx.vfs, %{grant: ["fs", "exec"]})
      perms = %{grant: ["fs", "exec"], membrane: %{port: Server.port(srv), token: Server.token(srv)}}

      # `work` is NOT the first word here, so the whole line goes to bash; the shim function execs it
      # mid-pipe through the socket. Proves true piping of a host cap.
      out = Bash.run(ctx.vfs, "echo ignored | work help | head -1", perms)
      assert out =~ "compile + analyze"

      Server.stop(srv)
    )
  end
end
