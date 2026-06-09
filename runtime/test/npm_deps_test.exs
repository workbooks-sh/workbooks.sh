defmodule Workbooks.NpmDepsTest do
  # wb-spy.T1.1 — npm dependency parser. Drives Workbooks.PackageManager.parse_package_json_deps
  # over real on-disk package.json / package-lock.json fixtures (no network, no native exec).
  use ExUnit.Case, async: true

  alias Workbooks.PackageManager, as: PM

  defp tmp(files) do
    dir = Path.join(System.tmp_dir!(), "npmdeps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    dir
  end

  test "parses dependencies + devDependencies as ranges with nil pin (no lockfile)" do
    dir =
      tmp(%{
        "package.json" =>
          ~s({"name":"x","dependencies":{"ms":"^2.1.3","left-pad":"1.3.0"},"devDependencies":{"nanoid":"~4.0.0"}})
      })

    deps = PM.parse_package_json_deps(dir)

    assert deps == [
             %{name: "left-pad", req: "1.3.0", pin: nil},
             %{name: "ms", req: "^2.1.3", pin: nil},
             %{name: "nanoid", req: "~4.0.0", pin: nil}
           ]
  end

  test "skips non-registry protocol specs (git/file/link/workspace/url/github shorthand)" do
    dir =
      tmp(%{
        "package.json" =>
          ~s({"dependencies":{"ok":"^1.0.0","g":"git+https://x/y.git","f":"file:../p","w":"workspace:*","u":"https://x/y.tgz","gh":"user/repo"}})
      })

    assert PM.parse_package_json_deps(dir) == [%{name: "ok", req: "^1.0.0", pin: nil}]
  end

  test "package-lock v3 supplies exact pins; shallowest wins over nested" do
    dir =
      tmp(%{
        "package.json" => ~s({"dependencies":{"ms":"^2.0.0"}}),
        "package-lock.json" =>
          ~s({"lockfileVersion":3,"packages":{"":{"name":"root"},"node_modules/ms":{"version":"2.1.3"},"node_modules/foo/node_modules/ms":{"version":"2.0.0"}}})
      })

    assert PM.parse_package_json_deps(dir) == [%{name: "ms", req: "^2.0.0", pin: "2.1.3"}]
  end

  test "package-lock v3 resolves scoped package names" do
    dir =
      tmp(%{
        "package.json" => ~s({"dependencies":{"@scope/pkg":"^1.0.0"}}),
        "package-lock.json" =>
          ~s({"lockfileVersion":3,"packages":{"":{},"node_modules/@scope/pkg":{"version":"1.4.2"}}})
      })

    assert PM.parse_package_json_deps(dir) == [%{name: "@scope/pkg", req: "^1.0.0", pin: "1.4.2"}]
  end

  test "package-lock v1 dependencies map supplies pins" do
    dir =
      tmp(%{
        "package.json" => ~s({"dependencies":{"ms":"^2.0.0"}}),
        "package-lock.json" =>
          ~s({"lockfileVersion":1,"dependencies":{"ms":{"version":"2.1.1"}}})
      })

    assert PM.parse_package_json_deps(dir) == [%{name: "ms", req: "^2.0.0", pin: "2.1.1"}]
  end

  test "no package.json → empty list" do
    dir = tmp(%{})
    assert PM.parse_package_json_deps(dir) == []
  end

  test "malformed package.json → empty list (no crash)" do
    dir = tmp(%{"package.json" => "{not json"})
    assert PM.parse_package_json_deps(dir) == []
  end

  test "dep-free package.json → empty list" do
    dir = tmp(%{"package.json" => ~s({"name":"x","version":"1.0.0"})})
    assert PM.parse_package_json_deps(dir) == []
  end
end
