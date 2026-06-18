defmodule Nexus.AgentBashTest do
  use ExUnit.Case, async: false

  setup do
    vfs = Nexus.Agent.Vfs.new()
    on_exit(fn -> Nexus.Agent.Vfs.destroy(vfs) end)
    {:ok, vfs: vfs}
  end

  # ---- deterministic, no network, no wasm ----

  test "the `kits` builtin lists the catalog incl. the web kit", %{vfs: vfs} do
    out = Nexus.Agent.Bash.run(vfs, "kits")
    assert out =~ "coreutils"
    assert out =~ "web"
  end

  test "`help <kit>` is progressive disclosure (commands only on demand)", %{vfs: vfs} do
    assert Nexus.Agent.Bash.run(vfs, "help coreutils") =~ "ls"
    assert Nexus.Agent.Bash.run(vfs, "help web") =~ "fetch"
    assert Nexus.Agent.Bash.run(vfs, "help nope") =~ "no such kit"
  end

  test "an unknown command is graceful, not a crash", %{vfs: vfs} do
    assert Nexus.Agent.Bash.run(vfs, "frobnicate --x") =~ "command not found"
  end

  test "web fetch is SSRF-brokered — a private host is blocked (no network)", %{vfs: vfs} do
    assert Nexus.Agent.Bash.run(vfs, "fetch http://127.0.0.1:4000/secret") =~ "blocked"
    assert Nexus.Agent.Bash.run(vfs, "fetch") =~ "usage"
  end

  # ---- needs coreutils.wasm + wasmtime (guarded) ----

  @tag :kits
  test "runs real wasm CLI commands in the VFS, with pipes", %{vfs: vfs} do
    if File.exists?(Path.join(Nexus.Agent.Kits.root(), "coreutils.wasm")) and System.find_executable("wasmtime") do
      Nexus.Agent.Vfs.put(vfs, "d.txt", "b\na\nb\nc\na\n")
      assert Nexus.Agent.Bash.run(vfs, "cat /work/d.txt | sort | uniq") |> String.split() == ~w(a b c)
      assert Nexus.Agent.Bash.run(vfs, "echo hi there") |> String.trim() == "hi there"
    else
      :ok
    end
  end
end
