defmodule TinyLasers.WasmSessionTest do
  @moduledoc """
  Nexus.Wasm.Session (wb-tqxr): a stateful shell session on Washy — cwd + env persist across separate
  run/2 calls, file writes persist to /work, exit codes report, and the session survives a failed
  command. Replaces the wasmer subprocess session on the dense BEAM lane. Skips if the C lane isn't built.
  """
  use ExUnit.Case, async: false
  alias Nexus.Wasm.Session

  setup do
    if Nexus.Shell.available?() do
      dir = Path.join(System.tmp_dir!(), "wb-wsess-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, s} = Session.start_link(dir)
      {:ok, s: s, dir: dir}
    else
      {:ok, skip: true}
    end
  end

  test "cwd + env persist across separate run/2 calls", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] C wasm lane not built")
    else
      {_, 0} = Session.run(ctx.s, "mkdir -p /work/sub && cd /work/sub && export Y=42")
      {out, code} = Session.run(ctx.s, "pwd; echo Y=$Y")
      assert code == 0
      assert out =~ "/work/sub"
      assert out =~ "Y=42"
    end
  end

  test "writes persist to the real host /work dir", ctx do
    if ctx[:skip] do
      :ok
    else
      {_, 0} = Session.run(ctx.s, "echo hello-session > /work/out.txt")
      {body, 0} = Session.run(ctx.s, "cat /work/out.txt")
      assert body == "hello-session\n"
      assert File.read!(Path.join(ctx.dir, "out.txt")) == "hello-session\n"
    end
  end

  test "a non-zero exit code is reported; the session survives a failed command", ctx do
    if ctx[:skip] do
      :ok
    else
      {_, code} = Session.run(ctx.s, "false")
      assert code == 1
      {_, 0} = Session.run(ctx.s, "true")
    end
  end

  test "relative cd composes against the tracked cwd", ctx do
    if ctx[:skip] do
      :ok
    else
      Session.run(ctx.s, "cd /work/a/b")
      Session.run(ctx.s, "cd ..")
      {out, 0} = Session.run(ctx.s, "pwd")
      assert String.trim(out) == "/work/a"
    end
  end
end
