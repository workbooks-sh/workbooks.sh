defmodule Nexus.WasmerCliTest do
  @moduledoc """
  The WASIX lane: real bash + real coreutils in wasm via wasmer, sandboxed to /work. Runs only when the
  wasmer runtime is present (CI without it skips cleanly). Asserts the cases that work today with the
  prebuilt packages (direct pipes/chains/glob with absolute /work paths); the package-rebuild task
  (wb-…) tracks the known gaps (nested $()-with-pipe, grep/sed/awk, fork cwd).
  """
  use ExUnit.Case, async: false

  @moduletag :wasix

  setup do
    if Nexus.WasmerCli.available?(), do: :ok, else: {:ok, skip: true}
  end

  defp work(files) do
    dir = Path.join(System.tmp_dir!(), "wb-wasix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    for {n, c} <- files, do: File.write!(Path.join(dir, n), c)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "real bash + coreutils: ls, pipe, chain, glob over /work", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] wasmer not installed — WASIX lane not exercised")
    else
      dir = work(%{"a.work" => "l1\nl2\nl3\n", "b.work" => "x"})

      {out, ok} = Nexus.WasmerCli.run("ls /work", dir)
      assert ok and out =~ "a.work" and out =~ "b.work"

      {out, ok} = Nexus.WasmerCli.run("cat /work/a.work | wc -l", dir)
      assert ok and String.trim(out) == "3"

      {out, ok} = Nexus.WasmerCli.run("for f in /work/*.work; do echo got $f; done && echo DONE", dir)
      assert ok and out =~ "got /work/a.work" and out =~ "DONE"
    end
  end

  test "flag-gated routing: non-host lines → real bash; host builtins → Elixir shell", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] wasmer not installed")
    else
      prev = Nexus.Config.wasix_shell?()
      Nexus.Config.put(:wasix_shell, true)
      on_exit(fn -> Nexus.Config.put(:wasix_shell, prev) end)

      dir = work(%{"a.work" => "l1\nl2\n"})
      vfs = Nexus.Agent.Vfs.attach(dir)

      # Non-host line routes to real bash (correct pipe output)…
      assert Nexus.Agent.Bash.run(vfs, "cat /work/a.work | wc -l", %{grant: ["fs", "exec"]}) |> String.trim() == "2"
      # …a host builtin stays on the Elixir lane (real bash can't call it).
      assert Nexus.Agent.Bash.run(vfs, "work help", %{grant: ["exec"]}) =~ "compile + analyze"
    end
  end

  test "the teardown crash is stripped from output", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] wasmer not installed")
    else
      dir = work(%{"a.work" => "hello\n"})
      {out, ok} = Nexus.WasmerCli.run("cat /work/a.work | cat", dir)
      assert ok
      refute out =~ "indirect call type mismatch"
      refute out =~ "RuntimeError"
      assert out =~ "hello"
    end
  end
end
