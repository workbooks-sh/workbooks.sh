defmodule Workbooks.NpmResolverTest do
  # wb-spy.T1.2 — npm registry resolver. The semver matcher is exercised deterministically
  # offline (real Workbooks.Npm.satisfies?/pick_version, not a stub); a @tag :netdeps test
  # resolves a real package against registry.npmjs.org and degrades gracefully when offline.
  use ExUnit.Case, async: true

  alias Workbooks.Npm

  describe "satisfies?/2 — node-semver subset" do
    test "caret keeps left-most non-zero fixed" do
      assert Npm.satisfies?("1.2.3", "^1.2.3")
      assert Npm.satisfies?("1.9.9", "^1.2.3")
      refute Npm.satisfies?("2.0.0", "^1.2.3")
      refute Npm.satisfies?("1.2.2", "^1.2.3")
      # ^0.2.3 → >=0.2.3 <0.3.0
      assert Npm.satisfies?("0.2.9", "^0.2.3")
      refute Npm.satisfies?("0.3.0", "^0.2.3")
      # ^0.0.3 → >=0.0.3 <0.0.4
      assert Npm.satisfies?("0.0.3", "^0.0.3")
      refute Npm.satisfies?("0.0.4", "^0.0.3")
    end

    test "tilde allows patch (or minor with only major)" do
      assert Npm.satisfies?("1.2.9", "~1.2.3")
      refute Npm.satisfies?("1.3.0", "~1.2.3")
      # ~1.2 → >=1.2.0 <1.3.0
      assert Npm.satisfies?("1.2.0", "~1.2")
      refute Npm.satisfies?("1.3.0", "~1.2")
      # ~1 → >=1.0.0 <2.0.0
      assert Npm.satisfies?("1.5.0", "~1")
      refute Npm.satisfies?("2.0.0", "~1")
    end

    test "exact and = equality" do
      assert Npm.satisfies?("1.2.3", "1.2.3")
      assert Npm.satisfies?("1.2.3", "=1.2.3")
      refute Npm.satisfies?("1.2.4", "1.2.3")
    end

    test "x-ranges and wildcards" do
      assert Npm.satisfies?("1.2.9", "1.2.x")
      refute Npm.satisfies?("1.3.0", "1.2.x")
      assert Npm.satisfies?("1.9.9", "1.x")
      refute Npm.satisfies?("2.0.0", "1.x")
      assert Npm.satisfies?("9.9.9", "*")
      assert Npm.satisfies?("9.9.9", "")
    end

    test "comparators and AND-clauses" do
      assert Npm.satisfies?("1.5.0", ">=1.2.0 <2.0.0")
      refute Npm.satisfies?("2.0.0", ">=1.2.0 <2.0.0")
      assert Npm.satisfies?("1.2.0", ">=1.2.0")
      refute Npm.satisfies?("1.1.9", ">=1.2.0")
      assert Npm.satisfies?("1.2.0", "<=1.2")
      refute Npm.satisfies?("1.3.0", "<=1.2")
    end

    test "|| unions" do
      assert Npm.satisfies?("1.0.0", "^1.0.0 || ^2.0.0")
      assert Npm.satisfies?("2.5.0", "^1.0.0 || ^2.0.0")
      refute Npm.satisfies?("3.0.0", "^1.0.0 || ^2.0.0")
    end
  end

  describe "pick_version/2 — over a synthetic packument" do
    @doc_fixture %{
      "dist-tags" => %{"latest" => "2.1.3", "next" => "3.0.0-beta.1"},
      "versions" => %{
        "1.0.0" => %{"dist" => %{"tarball" => "u/1.0.0"}},
        "2.0.0" => %{"dist" => %{"tarball" => "u/2.0.0"}},
        "2.1.3" => %{"dist" => %{"tarball" => "u/2.1.3"}, "dependencies" => %{"x" => "^1"}},
        "3.0.0-beta.1" => %{"dist" => %{"tarball" => "u/3.0.0-beta.1"}}
      }
    }

    test "picks highest satisfying stable version" do
      assert Npm.pick_version(@doc_fixture, "^2.0.0") == {:ok, "2.1.3"}
      assert Npm.pick_version(@doc_fixture, "^1.0.0") == {:ok, "1.0.0"}
    end

    test "empty/*/latest → dist-tags.latest" do
      assert Npm.pick_version(@doc_fixture, "") == {:ok, "2.1.3"}
      assert Npm.pick_version(@doc_fixture, "*") == {:ok, "2.1.3"}
      assert Npm.pick_version(@doc_fixture, "latest") == {:ok, "2.1.3"}
    end

    test "dist-tag by name" do
      assert Npm.pick_version(@doc_fixture, "next") == {:ok, "3.0.0-beta.1"}
    end

    test "prerelease excluded unless range names one" do
      # ^3.0.0 with no prerelease in range → the only 3.x is a prerelease → no match
      assert Npm.pick_version(@doc_fixture, "^3.0.0") == {:error, {:no_matching_version, "^3.0.0"}}
    end

    test "no satisfying version" do
      assert Npm.pick_version(@doc_fixture, "^9.0.0") == {:error, {:no_matching_version, "^9.0.0"}}
    end
  end

  @tag :netdeps
  @tag timeout: 60_000
  test "resolves a real package against registry.npmjs.org (degrades gracefully offline)" do
    case Npm.resolve("ms", "^2.1.0") do
      {:ok, r} ->
        assert r.name == "ms"
        assert Npm.satisfies?(r.version, "^2.1.0")
        assert is_binary(r.tarball) and String.contains?(r.tarball, "ms")
        assert is_map(r.deps)

      {:error, reason} ->
        IO.puts("\n[skip] npm resolve ms: #{inspect(reason) |> String.slice(0, 80)}")
    end
  end
end
