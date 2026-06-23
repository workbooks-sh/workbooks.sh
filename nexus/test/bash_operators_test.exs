defmodule Nexus.BashOperatorsTest do
  @moduledoc """
  The agent shell emulates real bash command lists: `;` (sequence), `&&` (run if prev succeeded), `||`
  (run if prev failed) — over pipelines/redirects/heredocs. Agents write these by instinct, so honoring
  them (with exit-status short-circuit) cuts wasted turns. Split is quote- and heredoc-aware.
  """
  use ExUnit.Case, async: false
  alias Nexus.Agent.{Bash, Vfs}

  describe "command-list parsing" do
    test "splits on ; && || but not | or quoted/heredoc operators" do
      assert [first: "a", and: "b", or: "c", seq: "d"] = Bash.split_command_list_for_test("a && b || c ; d")
      assert [first: "ls | grep x", and: "echo done"] = Bash.split_command_list_for_test("ls | grep x && echo done")
      assert [first: ~s(echo "a ; b && c")] = Bash.split_command_list_for_test(~s(echo "a ; b && c"))
    end

    test "a heredoc body is opaque; commands after the closing delimiter still split" do
      assert [first: "cat > f <<'EOF'\nx && y ; z\nEOF", seq: "work check"] =
               Bash.split_command_list_for_test("cat > f <<'EOF'\nx && y ; z\nEOF\nwork check")
    end
  end

  describe "execution semantics" do
    setup do
      base = Path.join(System.tmp_dir!(), "wb-ops-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      {:ok, vfs: Vfs.attach(base), dir: base}
    end

    test "write-then-check in ONE call via `&&`", %{vfs: vfs, dir: dir} do
      out = Bash.run(vfs, "printf 'server :hi do\\n  def ping, do: :ok\\nend\\n' > hi.work && work check", %{grant: ["fs", "exec"]})
      assert File.read!(Path.join(dir, "hi.work")) =~ "server :hi"
      assert out =~ "work check: OK"
    end

    test "`&&` short-circuits when the left command fails", %{vfs: vfs, dir: dir} do
      Bash.run(vfs, "false && printf x > made.work", %{grant: ["fs", "exec"]})
      refute File.exists?(Path.join(dir, "made.work")), "&& must skip the right side after a failure"
    end

    test "`||` runs the fallback only when the left fails", %{vfs: vfs, dir: dir} do
      Bash.run(vfs, "false || printf ok > fallback.work", %{grant: ["fs", "exec"]})
      assert File.exists?(Path.join(dir, "fallback.work"))
      Bash.run(vfs, "true || printf no > skip.work", %{grant: ["fs", "exec"]})
      refute File.exists?(Path.join(dir, "skip.work"))
    end

    test "`;` runs both regardless of status", %{vfs: vfs, dir: dir} do
      Bash.run(vfs, "false ; printf a > one.work ; printf b > two.work", %{grant: ["fs", "exec"]})
      assert File.exists?(Path.join(dir, "one.work")) and File.exists?(Path.join(dir, "two.work"))
    end
  end

  describe "expansion" do
    setup do
      base = Path.join(System.tmp_dir!(), "wb-exp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      File.write!(Path.join(base, "a.work"), "Aaa")
      File.write!(Path.join(base, "b.work"), "Bbb")
      on_exit(fn -> File.rm_rf(base) end)
      {:ok, vfs: Nexus.Agent.Vfs.attach(base)}
    end

    test "globs expand against /work (guest-absolute), no-match stays literal", %{vfs: vfs} do
      assert Nexus.Agent.Bash.run(vfs, "cat /work/*.work", %{grant: ["fs", "exec"]}) =~ "Aaa"
      assert Nexus.Agent.Bash.run(vfs, "cat *.work", %{grant: ["fs", "exec"]}) =~ "Bbb"
      assert Nexus.Agent.Bash.run(vfs, "echo /work/*.nope", %{grant: ["fs", "exec"]}) =~ "*.nope"
    end

    test "command substitution $(...) runs the inner command and inlines its output", %{vfs: vfs} do
      assert Nexus.Agent.Bash.run(vfs, "echo count=$(ls /work | wc -l)", %{grant: ["fs", "exec"]}) =~ "count=2"
    end
  end
end
