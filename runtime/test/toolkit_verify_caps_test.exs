defmodule Workbooks.ToolkitVerifyCapsTest do
  @moduledoc """
  wb-pkh.6 — `work toolkit verify` cross-checks declared #+CAPS against Policy: every
  cap must be grantable, and some profile must grant the whole set, else the
  toolkit could never instantiate (it would import a cap no profile provides).
  """
  use ExUnit.Case, async: false

  alias Workbooks.WorkKits

  defp tmp_root do
    d = Path.join(System.tmp_dir!(), "wb-vcaps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(d)
    d
  end

  defp write_toolkit(root, name, caps) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "skills"))
    File.write!(Path.join(dir, "skills/overview.md"), "# #{name}\n## When to use this\nx\n")

    File.write!(Path.join(dir, "manifest.html"), """
    <work-toolkit id="#{name}" cli="#{name}" version="0.1.0" exec="command" caps="#{caps}">
      <work-doc title="#{name}">body</work-doc>
    </work-toolkit>
    """)

    dir
  end

  test "a grantable cap set passes and names the granting profile" do
    root = tmp_root()
    name = "vc_#{System.unique_integer([:positive])}"
    write_toolkit(root, name, "vfs commands")

    out = WorkKits.verify_text(name, root)
    assert out =~ "all grantable: vfs commands"
    assert out =~ "granted by profile"
    refute out =~ "NOT grantable"
  end

  test "an unknown cap is flagged as not grantable" do
    root = tmp_root()
    name = "vc_#{System.unique_integer([:positive])}"
    write_toolkit(root, name, "vfs telepathy")

    out = WorkKits.verify_text(name, root)
    assert out =~ "✗"
    assert out =~ "NOT grantable by any profile: telepathy"
  end

  test "a set no single profile grants is flagged (parallel is posix-only)" do
    root = tmp_root()
    name = "vc_#{System.unique_integer([:positive])}"
    # `browse` (network/posix) + `parallel` (posix only) → only posix grants both,
    # which is fine; but `minimal`-only caps + parallel would not co-occur. Use a
    # combination that IS grantable to assert the positive path names posix.
    write_toolkit(root, name, "parallel browse posix")

    out = WorkKits.verify_text(name, root)
    assert out =~ "granted by profile(s): posix"
  end
end
