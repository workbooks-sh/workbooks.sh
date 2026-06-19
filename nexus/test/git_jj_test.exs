defmodule Nexus.GitJJTest do
  use ExUnit.Case, async: true

  defp tmp do
    d = Path.join(System.tmp_dir!(), "gitjj_#{System.unique_integer([:positive])}")
    File.mkdir_p!(d)
    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  test "Nexus.Git: ensure makes a repo; commit records; log lists; re-commit is :nochange" do
    dir = tmp()
    refute Nexus.Git.repo?(dir)
    Nexus.Git.ensure(dir)
    assert Nexus.Git.repo?(dir)

    File.write!(Path.join(dir, "a.work"), "# Page\n")
    assert {:ok, sha} = Nexus.Git.commit(dir, "add a.work")
    assert is_binary(sha) and byte_size(sha) > 0

    log = Nexus.Git.log(dir)
    assert [%{message: "add a.work"} | _] = log

    assert Nexus.Git.commit(dir, "no changes") == :nochange
  end

  @tag :jj
  test "Nexus.JJ: colocates + yields a structured op-log (when jj is installed)" do
    dir = tmp()
    File.write!(Path.join(dir, "a.work"), "# Page\n")
    Nexus.Git.commit(dir, "init")

    if Nexus.JJ.available?() do
      assert Nexus.JJ.ensure(dir) == :ok
      entries = Nexus.JJ.op_entries(dir)
      assert is_list(entries)
      assert Enum.all?(entries, &(&1.id =~ ~r/\A[0-9a-f]{4,}\z/))
    else
      # No-op-safe: degrades cleanly without the binary.
      assert {:skip, _} = Nexus.JJ.ensure(dir)
      assert Nexus.JJ.op_entries(dir) == []
    end
  end
end
