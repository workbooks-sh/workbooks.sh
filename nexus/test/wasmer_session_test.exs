defmodule Nexus.Wasmer.SessionTest do
  @moduledoc """
  The long-lived per-agent bash session (Phase 6) — state PERSISTS across commands (cwd, env), writes hit
  the real `/work`, and exit codes come back. Runs only when wasmer is present; skips otherwise.
  """
  use ExUnit.Case, async: false
  alias Nexus.Wasmer.Session

  @moduletag :wasmer

  setup do
    if Nexus.Wasmer.available?() do
      dir = Path.join(System.tmp_dir!(), "wb-sess-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    else
      {:ok, skip: true}
    end
  end

  test "cwd + env persist across separate run/2 calls", %{} = ctx do
    if ctx[:skip], do: IO.puts("\n[skip] wasmer absent"), else: (
      {:ok, s} = Session.start_link(ctx.dir)
      {_, 0} = Session.run(s, "mkdir -p /work/sub && cd /work/sub && export Y=42")
      {out, code} = Session.run(s, "pwd; echo Y=$Y")
      assert code == 0
      assert out =~ "/work/sub"
      assert out =~ "Y=42"
      Session.stop(s)
    )
  end

  test "writes persist to the real host /work dir", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      {:ok, s} = Session.start_link(ctx.dir)
      {_, 0} = Session.run(s, "echo hello-session > /work/out.txt")
      {body, 0} = Session.run(s, "cat /work/out.txt")
      assert body == "hello-session\n"
      assert File.read!(Path.join(ctx.dir, "out.txt")) == "hello-session\n"
      Session.stop(s)
    )
  end

  test "a non-zero exit code is reported", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      {:ok, s} = Session.start_link(ctx.dir)
      {_, code} = Session.run(s, "false")
      assert code == 1
      {_, 0} = Session.run(s, "true")  # session survives a failed command
      Session.stop(s)
    )
  end

  test "Bash.run routes through a session in perms — cwd persists across agent commands", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      vfs = Nexus.Agent.Vfs.attach(ctx.dir)
      {:ok, s} = Session.start_link(ctx.dir)
      perms = %{grant: ["fs", "exec"], session: s}
      Nexus.Agent.Bash.run(vfs, "mkdir -p /work/d && cd /work/d", perms)
      out = Nexus.Agent.Bash.run(vfs, "pwd", perms) |> String.trim()
      assert out == "/work/d"
      Session.stop(s)
    )
  end
end
