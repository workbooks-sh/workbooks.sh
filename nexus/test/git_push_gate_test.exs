defmodule Nexus.GitPushGateTest do
  @moduledoc """
  THE live-push test (the "final note"): drive a REAL `git push` through the provisioned pre-receive
  hook so the authorship sig-gate runs against git's actual quarantine — proving the hook fires, the
  quarantined commits are readable, and :hard accepts a signed commit / rejects an unsigned one.

  WB_NEXUS_BIN points at a wrapper that runs the REAL `Nexus.Git.sig_gate!` via `mix run` (forcing the
  :hard policy), and stubs the compile gate (not under test here). Skips cleanly if mix/ssh-keygen are
  unavailable.
  """
  use ExUnit.Case, async: false
  alias Nexus.{GitSign, Keyring}

  @moduletag :integration

  setup_all do
    if System.find_executable("mix") && System.find_executable("ssh-keygen") &&
         System.find_executable("git"),
       do: :ok,
       else: {:ok, skip: true}
  end

  defp sh(args, opts), do: System.cmd("git", args, [stderr_to_stdout: true] ++ opts)

  test "a :hard nexus accepts a signed push and rejects an unsigned one", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] mix/ssh-keygen/git unavailable — live push-gate not exercised")
    else
      nexus_dir = File.cwd!()
      base = Path.join(System.tmp_dir!(), "wb-pushgate-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      # Scope the runtime's data dir (durable_dir → allowed_signers path) to this test.
      prev_data = System.get_env("WB_DATA")
      System.put_env("WB_DATA", base)
      on_exit(fn -> if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA") end)

      # NEXUS_BIN wrapper: stub the compile gate, run the REAL sig_gate! for everything else (policy forced).
      bin = Path.join(base, "nexusbin")
      File.write!(bin, """
      #!/bin/sh
      case "$2" in
        *Compile.gate*) exit 0 ;;
        *) cd "#{nexus_dir}" && exec mix run --no-start -e "Nexus.Config.put(:authorship_policy, \\"$WB_TEST_POLICY\\"); $2" ;;
      esac
      """)
      File.chmod!(bin, 0o755)

      # A device key (ssh) → its DID → the deploy's allowed-signers file the gate reads.
      key = Path.join(base, "id")
      {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-f", key, "-N", "", "-q"], stderr_to_stdout: true)
      {:ok, pub} = GitSign.pub_from_ssh_line(File.read!(key <> ".pub"))
      GitSign.write_allowed_signers([{"dev@example.com", Keyring.did(pub)}])

      # Provision the bare repo (installs the real pre-receive/post-receive hooks).
      bare = Nexus.Git.bare_path(Nexus.Paths.repos_root(), "pushgate")
      work = Nexus.Paths.work_dir("pushgate")
      {:ok, ^bare} = Nexus.Git.provision_remote(bare, work)

      # Client repo, configured to SSH-sign commits with the device key.
      client = Path.join(base, "client")
      File.mkdir_p!(client)
      cfg = fn k, v -> sh(["-C", client, "config", k, v], []) end
      sh(["-C", client, "init", "-q", "-b", "main"], [])
      cfg.("user.email", "dev@example.com")
      cfg.("user.name", "dev")
      cfg.("gpg.format", "ssh")
      cfg.("user.signingkey", key)
      cfg.("commit.gpgsign", "true")

      push_env = [{"WB_NEXUS_BIN", bin}, {"WB_TEST_POLICY", "hard"}, {"WB_DATA", base}]

      # ── 1) signed commit → push ACCEPTED ──
      File.write!(Path.join(client, "a.txt"), "hello")
      sh(["-C", client, "add", "-A"], [])
      {_, 0} = sh(["-C", client, "commit", "-q", "-m", "signed"], [])
      {out1, code1} = sh(["-C", client, "push", bare, "main"], env: push_env)
      assert code1 == 0, "signed push should be accepted under :hard, got:\n#{out1}"

      # ── 2) UNSIGNED commit → push REJECTED ──
      sh(["-C", client, "config", "commit.gpgsign", "false"], [])
      File.write!(Path.join(client, "b.txt"), "x")
      sh(["-C", client, "add", "-A"], [])
      {_, 0} = sh(["-C", client, "commit", "-q", "-m", "unsigned"], [])
      {out2, code2} = sh(["-C", client, "push", bare, "main"], env: push_env)
      assert code2 != 0, "unsigned push must be rejected under :hard"
      assert out2 =~ "push rejected", "expected the sig-gate rejection message, got:\n#{out2}"
    end
  end
end
