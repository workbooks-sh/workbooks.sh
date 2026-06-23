defmodule Nexus.AgentShellWasmerTest do
  @moduledoc """
  The new agent shell: REAL bash + full coreutils on **Wasmer** over /work (Nexus.Wasmer), with host
  capabilities (work/agent/web) dispatched in Elixir. Validates the architecture empirically + adversarially:
  real grammar, real coreutils, real FS, the /work sandbox boundary, and host-cap routing. Runs only when
  the wasmer runtime is present; skips cleanly otherwise.
  """
  use ExUnit.Case, async: false
  alias Nexus.Agent.{Bash, Vfs}

  @moduletag :wasmer

  setup do
    if Nexus.Wasmer.available?() do
      dir = Path.join(System.tmp_dir!(), "wb-sh-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, vfs: Vfs.attach(dir), dir: dir}
    else
      {:ok, skip: true}
    end
  end

  defp run(vfs, line), do: Bash.run(vfs, line, %{grant: ["fs", "exec"]}) |> String.trim()

  describe "real bash grammar + full coreutils" do
    test "pipes, sort/uniq, and chaining produce correct output", %{vfs: vfs, dir: dir} = ctx do
      if ctx[:skip], do: IO.puts("\n[skip] wasmer absent"), else: (
        File.write!(Path.join(dir, "a.txt"), "banana\napple\ncherry\napple\n")
        assert run(vfs, "sort /work/a.txt | uniq -c | sort -rn | head -1") =~ "apple"
        assert run(vfs, "tail -2 /work/a.txt") == "cherry\napple"
        assert run(vfs, "cut -c1-3 /work/a.txt | sort -u | wc -l") == "3"
        assert run(vfs, "true && echo yes || echo no") == "yes"
        assert run(vfs, "false && echo yes || echo no") == "no"
        assert run(vfs, "for i in 1 2 3; do echo n$i; done") == "n1\nn2\nn3"
      )
    end
  end

  describe "real filesystem over /work" do
    test "writes persist to the real host dir", %{vfs: vfs, dir: dir} = ctx do
      if ctx[:skip], do: IO.puts("\n[skip] wasmer absent"), else: (
        run(vfs, "echo hello > /work/out.txt")
        assert File.read!(Path.join(dir, "out.txt")) == "hello\n"
        run(vfs, "mkdir -p /work/sub && printf 'multi\\nline\\n' > /work/sub/f.txt")
        assert File.read!(Path.join(dir, "sub/f.txt")) == "multi\nline\n"
      )
    end
  end

  describe "the /work sandbox boundary (adversarial)" do
    test "cannot read host files outside /work", %{vfs: vfs} = ctx do
      if ctx[:skip], do: IO.puts("\n[skip] wasmer absent"), else: (
        secret = Path.join(System.tmp_dir!(), "wb-secret-#{System.unique_integer([:positive])}.txt")
        File.write!(secret, "TOPSECRET")
        on_exit(fn -> File.rm(secret) end)
        refute run(vfs, "cat #{secret}") =~ "TOPSECRET"
        refute run(vfs, "cat ../#{Path.basename(secret)}") =~ "TOPSECRET"
        # the guest root is a virtual FS, not the host root
        refute run(vfs, "ls /") =~ "Users"
      )
    end
  end

  describe "host-capability routing (stays Elixir)" do
    test "work runs in-process; bash never sees it", %{vfs: vfs, dir: dir} = ctx do
      if ctx[:skip], do: IO.puts("\n[skip] wasmer absent"), else: (
        File.write!(Path.join(dir, "x.work"), "A unit.\n\nserver :x do\n  def f, do: :ok\nend\n")
        assert run(vfs, "work check") =~ "work check: OK"
        assert run(vfs, "work help") =~ "compile + analyze"
      )
    end
  end
end
