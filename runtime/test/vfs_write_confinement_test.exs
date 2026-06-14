defmodule Workbooks.VfsWriteConfinementTest do
  @moduledoc """
  Pins the agent's vfs_write tool (exec path) — the arg→effect that lets Waldo
  create workbook content, AND its safe_path confinement: a write must land inside
  the agent's workdir and an escaping path (../../) must be BLOCKED with no file
  written outside. This is security-relevant (a prompt-injected agent must not be
  able to scribble over the host fs) and was untested at the tool level.
  Deterministic: real temp workdir, no LLM.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Agent

  setup do
    dir = Path.join(System.tmp_dir!(), "vfs-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, workdir: dir}
  end

  test "a normal write lands inside the workdir with the right bytes", %{workdir: dir} do
    {out, _st} =
      Agent.__exec_one_for_test__(
        %{name: "vfs_write", args: %{"path" => "notes/hello.org", "content" => "* Hi\n"}},
        %{exec: true, workdir: dir}
      )

    assert out =~ "wrote"
    assert File.read!(Path.join(dir, "notes/hello.org")) == "* Hi\n"
  end

  test "an escaping path is BLOCKED and nothing is written outside the workdir", %{workdir: dir} do
    outside = Path.join(System.tmp_dir!(), "vfs-escape-#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm_rf(outside) end)

    {out, _st} =
      Agent.__exec_one_for_test__(
        %{name: "vfs_write", args: %{"path" => "../../../../../../../../#{Path.basename(outside)}", "content" => "pwned"}},
        %{exec: true, workdir: dir}
      )

    assert out =~ "blocked"
    refute File.exists?(outside)
  end

  test "vfs_read round-trips a vfs_write within the workdir", %{workdir: dir} do
    Agent.__exec_one_for_test__(
      %{name: "vfs_write", args: %{"path" => "a/b.txt", "content" => "roundtrip"}},
      %{exec: true, workdir: dir}
    )

    {out, _st} =
      Agent.__exec_one_for_test__(
        %{name: "vfs_read", args: %{"path" => "a/b.txt"}},
        %{exec: true, workdir: dir}
      )

    assert out == "roundtrip"
  end
end
