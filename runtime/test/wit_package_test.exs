defmodule Workbooks.WitPackageTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Literate, Wit}

  @src """
  # Demo

  defmodule Lead do
    defstruct name: "", revenue: 0
  end

  @statuses [:new, :scored]

  server :score do
    def score(%Lead{} = lead), do: lead.revenue
  end

  server :enrich, grant: [net: "x"] do
    def enrich(lead), do: Dock.fetch("https://x")
  end
  """

  test "package/1 assembles a self-contained WIT package, validated by wasm-tools" do
    pkg = Literate.parse(@src) |> Wit.package("demo")

    assert pkg =~ "package work:demo;"
    assert pkg =~ "interface host-net {"
    assert pkg =~ "interface types {"
    assert pkg =~ "world score {"
    assert pkg =~ "use types.{lead};"
    assert pkg =~ "world enrich {"
    assert pkg =~ "import host-net;"

    case Wit.validate(pkg) do
      :ok -> :ok
      {:error, "wasm-tools unavailable" <> _} -> :ok
      {:error, msg} -> flunk("generated WIT did not validate:\n#{msg}\n\n--- package ---\n#{pkg}")
    end
  end

  test "every file in the real demo tree generates WIT that wasm-tools validates" do
    demo = Path.expand("../workponents/sales", File.cwd!())

    if File.dir?(demo) do
      paths = (Path.wildcard(Path.join(demo, "*.work")) ++ Path.wildcard(Path.join(demo, "**/*.work"))) |> Enum.uniq()

      failures =
        for path <- paths,
            pkg = path |> File.read!() |> Literate.parse() |> Wit.package(Path.basename(path, ".work")),
            {:error, msg} <- [Wit.validate(pkg)],
            not String.starts_with?(msg, "wasm-tools unavailable"),
            do: {Path.basename(path), msg}

      assert failures == [], "demo files produced invalid WIT:\n" <> Enum.map_join(failures, "\n", fn {f, m} -> "#{f}: #{m}" end)
    end
  end
end
