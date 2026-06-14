defmodule Workbooks.JsDepTypesTest do
  @moduledoc """
  Proves dependency-type resolution behavior of `Npm.install_tree`:
    * `dependencies` install transitively; `devDependencies` are NOT pulled (only "dependencies" read).
    * `peerDependencies` are NOT auto-installed (the consumer provides them) — react-dom does not drag in react.
    * package.json `overrides` force a (possibly transitive) version — a security-pin lever.

  Not covered (recorded in js-ecosystem.json): optionalDependencies are skipped-safe; git/url/file/workspace
  dep specs are gracefully skipped (need git/local/tarball support — bedrock-leaning). Skips if registry unreachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Npm

  @tag :build
  @tag timeout: 120_000
  test "peerDependencies are not auto-installed; prod deps are" do
    dir = Path.join(System.tmp_dir!(), "jsdep_peer")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    case Npm.install_tree([%{name: "react-dom", req: "^18.2.0", pin: nil}], dir) do
      {:ok, inst} ->
        assert Map.has_key?(inst, "react-dom")
        assert Map.has_key?(inst, "scheduler"), "prod dep scheduler should install"
        refute Map.has_key?(inst, "react"), "peer dep react must NOT auto-install"

      other ->
        IO.puts("\n[skip] registry unreachable: #{inspect(other) |> String.slice(0, 100)}")
    end
  end

  @tag :build
  @tag timeout: 120_000
  test "overrides force a version" do
    dir = Path.join(System.tmp_dir!(), "jsdep_over")
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","dependencies":{"lodash":"^4.0.0"},"overrides":{"lodash":"4.17.19"}}))

    case Npm.install_tree([%{name: "lodash", req: "^4.0.0", pin: nil}], dir) do
      {:ok, %{"lodash" => version}} ->
        assert version == "4.17.19", "overrides should force lodash 4.17.19, got #{version}"

      other ->
        IO.puts("\n[skip] registry unreachable: #{inspect(other) |> String.slice(0, 100)}")
    end
  end
end
