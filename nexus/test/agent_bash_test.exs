defmodule Nexus.AgentBashTest do
  use ExUnit.Case, async: false

  setup do
    vfs = Nexus.Agent.Vfs.new()
    on_exit(fn -> Nexus.Agent.Vfs.destroy(vfs) end)
    {:ok, vfs: vfs}
  end

  # ---- deterministic, no network, no wasm ----

  test "tools/grant ENFORCE: a kit outside tools is refused; a web cmd needs a web grant", %{vfs: vfs} do
    Nexus.Agent.Kits.register("rg", "rg.wasm", summary: "search")
    perms = %{tools: ["coreutils"], grant: []}

    assert Nexus.Agent.Bash.run(vfs, "rg foo", perms) =~ "not in this agent's tools"
    assert Nexus.Agent.Bash.run(vfs, "fetch http://example.com", perms) =~ "needs web access"

    refute Nexus.Agent.Bash.run(vfs, "fetch http://example.com", %{tools: ["coreutils"], grant: ["web"]}) =~
             "needs web access"

    refute Nexus.Agent.Bash.run(vfs, "rg foo", nil) =~ "not in this agent's tools"
  end

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

  defp kits_ready? do
    File.exists?(Path.join(Nexus.Agent.Kits.root(), "coreutils.wasm")) and System.find_executable("wasmtime") != nil
  end

  @tag :kits
  test "VFS sandbox CONFINES the guest — no read/write outside /work", %{vfs: vfs} do
    if kits_ready?() do
      # read of host files is denied — wasmtime grants ONLY the /work preopen.
      assert Nexus.Agent.Bash.run(vfs, "cat /etc/passwd") =~ "pre-opened file descriptor"
      assert Nexus.Agent.Bash.run(vfs, "ls /") =~ "pre-opened file descriptor"
      assert Nexus.Agent.Bash.run(vfs, "cat ../../../../../../etc/passwd") =~ "pre-opened file descriptor"
      # traversal out of the preopen is denied (pre-opened-fd error or Permission denied — both = confined).
      out_traversal = Nexus.Agent.Bash.run(vfs, "ls /work/../..")
      assert out_traversal =~ "pre-opened file descriptor" or out_traversal =~ "Permission denied"

      # a symlink created inside /work pointing OUT cannot be created (wasmtime denies it) — and even
      # if present, reading through it stays confined. Prove creation is denied.
      assert Nexus.Agent.Bash.run(vfs, "ln -s /etc/passwd /work/escape") =~ "Permission denied"

      # writes outside /work are denied too.
      assert Nexus.Agent.Bash.run(vfs, "touch /tmp/nexus_should_not_exist") =~ "pre-opened file descriptor"
      refute File.exists?("/tmp/nexus_should_not_exist")
    else
      :ok
    end
  end

  @tag :kits
  test "NO host-shell injection — metacharacters reach wasm argv literally, never the host sh", %{vfs: vfs} do
    if kits_ready?() do
      sentinel = Path.join(System.tmp_dir!(), "nexus_injection_#{System.unique_integer([:positive])}")
      File.rm(sentinel)
      # `;`, `$(...)`, backticks — all must reach `echo` as literal argv, NOT be evaluated by host sh.
      bt = <<96>>
      inj = "echo hi; touch " <> sentinel <> "; $(touch " <> sentinel <> ") " <>
              bt <> "touch " <> sentinel <> bt
      out = Nexus.Agent.Bash.run(vfs, inj)
      refute File.exists?(sentinel), "HOST SHELL INJECTION: #{sentinel} was created — shq broke out!"
      # the metacharacters appear in the echoed output (proof they were data, not host commands)
      assert out =~ "touch"
    else
      :ok
    end
  end

  @tag :kits
  test "a spinning kit (`yes`) is reaped by the per-command timeout — no infinite hang", %{vfs: vfs} do
    if File.exists?(Path.join(Nexus.Agent.Kits.root(), "coreutils.wasm")) and System.find_executable("wasmtime") do
      # squeeze the budget so the test is fast; `yes` would spin forever without the watchdog.
      prev = Application.get_env(:nexus, Nexus.Agent.Bash, [])
      Application.put_env(:nexus, Nexus.Agent.Bash, Keyword.put(prev, :cmd_timeout_ms, 1500))
      on_exit(fn -> Application.put_env(:nexus, Nexus.Agent.Bash, prev) end)

      t0 = System.monotonic_time(:millisecond)
      out = Nexus.Agent.Bash.run(vfs, "yes")
      took = System.monotonic_time(:millisecond) - t0

      assert took < 8_000, "yes hung for #{took}ms — watchdog did not reap it"
      assert out =~ "killed" and out =~ "time budget"
      # output is bounded (head+tail truncation is applied upstream in the agent, but the kit itself
      # was killed quickly so the buffer cannot grow without bound forever.
    else
      :ok
    end
  end

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
