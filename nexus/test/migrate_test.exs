defmodule Nexus.MigrateTest do
  @moduledoc "Repo import analysis: language detection, compatibility matrix, wrap-vs-rewrite."
  use ExUnit.Case, async: true
  alias Nexus.Migrate

  defp fixture(files) do
    dir = Path.join(System.tmp_dir!(), "mig_#{System.unique_integer([:positive])}")

    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "compatibility matrix classifies languages" do
    assert %{strategy: :wrap, support: :full} = Migrate.compatibility("javascript")
    assert %{strategy: :assist, support: :partial} = Migrate.compatibility("go")
    assert %{strategy: :rewrite, support: :none} = Migrate.compatibility("python")
    assert %{strategy: :rewrite} = Migrate.compatibility("cobol")
  end

  test "a pure Node repo recommends :wrap (bring as-is)" do
    dir = fixture([{"package.json", "{}"}, {"src/index.js", "console.log(1)"}, {"src/util.js", "1"}])
    r = Migrate.analyze(dir)
    assert "javascript" in r.languages
    assert r.recommendation == :wrap
  end

  test "a Go service recommends :assist (partial support)" do
    dir = fixture([{"go.mod", "module x"}, {"main.go", "package main"}])
    assert Migrate.analyze(dir).recommendation == :assist
  end

  test "a Python-dominated repo recommends :rewrite" do
    dir = fixture([{"requirements.txt", ""}, {"app.py", "x=1"}, {"lib.py", "y=2"}, {"util.py", "z=3"}])
    r = Migrate.analyze(dir)
    assert r.recommendation == :rewrite
    assert r.matrix["python"].strategy == :rewrite
  end

  test "node_modules / target / .git are ignored" do
    dir = fixture([{"index.js", "1"}, {"node_modules/dep/x.js", "1"}, {".git/config", "1"}])
    assert Migrate.analyze(dir).files_by_language["javascript"] == 1
  end

  test "an empty/unknown repo recommends :wrap (nothing to port)" do
    dir = fixture([{"README.md", "hi"}])
    assert Migrate.analyze(dir).recommendation == :wrap
  end

  test "files_by_language counts sources + manifests" do
    dir = fixture([{"package.json", "{}"}, {"a.js", "1"}, {"b.ts", "1"}])
    counts = Migrate.analyze(dir).files_by_language
    assert counts["javascript"] == 2
    assert counts["typescript"] == 1
  end
end
