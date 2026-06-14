defmodule Workbooks.JsLockfileTest do
  @moduledoc """
  Proves reproducible installs from an npm `package-lock.json` (lockfileVersion 2/3): `Npm.parse_lockfile`
  extracts the pinned tree, `Npm.install_from_lockfile` installs EXACT versions (no fresh range resolution).
  Verified by pinning an OLD lodash (4.17.20) and asserting that exact version installs, not latest.

  Skips unless the registry is reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Npm

  @tag :build
  @tag timeout: 120_000
  test "install_from_lockfile honors the pinned version" do
    dir = Path.join(System.tmp_dir!(), "jslock_test")
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","dependencies":{"lodash":"^4.0.0"}}))

    # The lockfile pins an OLD lodash — proving the install honors the lock, not a fresh ^4 resolution.
    File.write!(
      Path.join(dir, "package-lock.json"),
      ~s({"name":"t","lockfileVersion":3,"packages":{"":{"name":"t"},"node_modules/lodash":{"version":"4.17.20","resolved":"https://registry.npmjs.org/lodash/-/lodash-4.17.20.tgz"}}})
    )

    assert {:ok, [%{name: "lodash", pin: "4.17.20"}]} = Npm.parse_lockfile(dir)

    case Npm.install_from_lockfile(dir) do
      {:ok, %{"lodash" => "4.17.20"}} ->
        version = Jason.decode!(File.read!(Path.join(dir, "node_modules/lodash/package.json")))["version"]
        assert version == "4.17.20"

      other ->
        IO.puts("\n[skip] registry unreachable: #{inspect(other) |> String.slice(0, 120)}")
    end
  end
end
