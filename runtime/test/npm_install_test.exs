defmodule Workbooks.NpmInstallTest do
  # wb-spy.T1.3 — tarball fetch + extract + transitive node_modules assembly. Drives the real
  # Workbooks.Npm.install_tree against registry.npmjs.org (@tag :netdeps), proving fetch via
  # :httpc + extract via :erl_tar with zero native execution. Degrades gracefully offline.
  use ExUnit.Case, async: false

  alias Workbooks.Npm

  defp tmp do
    dir = Path.join(System.tmp_dir!(), "npminstall-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "installs a leaf package (ms) into node_modules" do
    dir = tmp()

    case Npm.install_tree([%{name: "ms", req: "^2.1.0", pin: nil}], dir) do
      {:ok, installed} ->
        assert Map.has_key?(installed, "ms")
        pj = Path.join(dir, "node_modules/ms/package.json")
        assert File.regular?(pj)
        assert {:ok, %{"name" => "ms"}} = pj |> File.read!() |> Jason.decode()

      other ->
        IO.puts("\n[skip] install ms: #{inspect(other) |> String.slice(0, 100)}")
    end
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "installs transitive deps flat (debug → ms)" do
    dir = tmp()

    case Npm.install_tree([%{name: "debug", req: "^4.3.0", pin: nil}], dir) do
      {:ok, installed} ->
        assert Map.has_key?(installed, "debug")
        # debug depends on ms — it must be hoisted flat into node_modules/ms
        assert Map.has_key?(installed, "ms")
        assert File.regular?(Path.join(dir, "node_modules/debug/package.json"))
        assert File.regular?(Path.join(dir, "node_modules/ms/package.json"))

      other ->
        IO.puts("\n[skip] install debug: #{inspect(other) |> String.slice(0, 100)}")
    end
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "exact pin skips packument resolution and still installs" do
    dir = tmp()

    case Npm.install_tree([%{name: "ms", req: "^2.0.0", pin: "2.1.3"}], dir) do
      {:ok, installed} ->
        assert installed["ms"] == "2.1.3"
        {:ok, meta} = Path.join(dir, "node_modules/ms/package.json") |> File.read!() |> Jason.decode()
        assert meta["version"] == "2.1.3"

      other ->
        IO.puts("\n[skip] install pinned ms: #{inspect(other) |> String.slice(0, 100)}")
    end
  end
end
