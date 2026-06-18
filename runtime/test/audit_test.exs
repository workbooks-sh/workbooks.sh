defmodule Workbooks.AuditTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Audit, Work}

  defp tree(files) do
    dir = Path.join(System.tmp_dir!(), "wbaudit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, src} -> File.write!(Path.join(dir, name), src) end)
    dir
  end

  test "a unit that grants a capability it uses is clean" do
    dir = tree(%{
      "enrich.work" => """
      # Enrich

      server :enrich, grant: [net: "api.crm.com"] do
        def enrich(lead), do: Dock.fetch("https://api.crm.com")
      end
      """
    })

    assert Audit.caps(dir) == []
    File.rm_rf!(dir)
  end

  test "a unit that uses a Dock capability without granting it is flagged" do
    dir = tree(%{
      "leaky.work" => """
      # Leaky

      server :leaky do
        def go, do: {Dock.fetch("https://x"), Dock.secret(:key)}
      end
      """
    })

    leaks = Audit.caps(dir)
    assert %{unit: "leaky", cap: "net"} in leaks
    assert %{unit: "leaky", cap: "secrets"} in leaks

    # and work check fails with the leak reported
    {out, failed?} = Work.CLI.check(dir)
    assert failed?
    assert out =~ "ungranted capability"
    assert out =~ ":leaky uses net"
    File.rm_rf!(dir)
  end

  test "non-Dock calls don't count as capability use" do
    dir = tree(%{
      "pure.work" => "# Pure\n\nserver :pure do\n  def f(l), do: Enum.map(l, &String.upcase/1)\nend\n"
    })

    assert Audit.caps(dir) == []
    File.rm_rf!(dir)
  end
end
