defmodule Nexus.ShellTest do
  @moduledoc """
  washy — our featured shell compiled to ONE wasm command module (clang.wasm → wasm32-wasip1 → AOT →
  wasmtime), NO wasmer/WASIX/fork. Pipes are buffered chaining in one process. Runs only when the C wasm
  lane is built; skips otherwise.
  """
  use ExUnit.Case, async: false

  setup_all do
    if Nexus.Shell.available?(), do: %{ok: true}, else: %{skip: true}
  end

  setup %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      dir = Path.join(System.tmp_dir!(), "wb-sh-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.txt"), "banana\napple\ncherry\napple\n")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    )
  end

  defp run(dir, line), do: Nexus.Shell.run(line, dir) |> elem(0) |> String.trim_trailing()

  test "buffered pipes + builtins over a real /work file", %{} = ctx do
    if ctx[:skip], do: IO.puts("\n[skip] C wasm lane not built"), else: (
      assert run(ctx.dir, "cat /work/a.txt | sort | uniq") == "apple\nbanana\ncherry"
      assert run(ctx.dir, "cat /work/a.txt | grep apple | wc -l") == "2"
      assert run(ctx.dir, "cat /work/a.txt | sort | uniq | wc -l") == "3"
      assert run(ctx.dir, "cat /work/a.txt | tail -2") == "cherry\napple"
      assert run(ctx.dir, "echo hi | upper | rev") == "IH"
    )
  end

  test "redirects write the real host tree; chaining short-circuits", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      Nexus.Shell.run("echo hello-shell > /work/out.txt", ctx.dir)
      assert File.read!(Path.join(ctx.dir, "out.txt")) |> String.trim() == "hello-shell"
      assert run(ctx.dir, "echo line2 >> /work/out.txt; cat /work/out.txt") == "hello-shell\nline2"
      assert run(ctx.dir, "true && echo yes") == "yes"
      assert run(ctx.dir, "false && echo no || echo recovered") == "recovered"
    )
  end

  test "the /work mount is the boundary — no host path outside it", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      secret = Path.join(System.tmp_dir!(), "wb-shsecret-#{System.unique_integer([:positive])}.txt")
      File.write!(secret, "TOPSECRET")
      on_exit(fn -> File.rm(secret) end)
      {out, _} = Nexus.Shell.run("cat #{secret}", ctx.dir)
      refute out =~ "TOPSECRET"
    )
  end

  # non-builtin commands delegate to the host (host_exec → coreutils): the shell provides GRAMMAR,
  # the host provides the full tool set. Skips if coreutils.wasm isn't present.
  test "delegates non-builtins to coreutils via host_exec, including in pipes", %{} = ctx do
    cond do
      ctx[:skip] -> :ok
      not File.exists?("kits/coreutils.wasm") -> IO.puts("\n[skip] coreutils.wasm absent")
      true ->
        run = fn line -> Nexus.Shell.run(line, ctx.dir) |> elem(0) end
        assert run.("seq 3") == "1\n2\n3\n"                          # not a builtin → host_exec
        assert run.("basename /a/b/c.txt") == "c.txt\n"
        assert run.("seq 5 | sort -r | head -2") == "5\n4\n"        # host_exec → builtin → builtin pipe
        assert run.("seq 3 | paste -sd+") == "1+2+3\n"              # builtin-less, both via host_exec/coreutils
        assert run.("echo hi | upper") == "HI\n"                    # builtins still work alongside
    end
  end
end
