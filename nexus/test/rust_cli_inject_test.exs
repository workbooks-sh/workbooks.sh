defmodule Nexus.Compilers.RustCliInjectTest do
  @moduledoc """
  The build-manifest transforms behind Layer 1: redirect reqwest to the host_http shim via
  [patch.crates-io], and trim tokio's features to the wasm-supported set — so an UNMODIFIED reqwest CLI
  compiles to wasm32-wasip1. Pure transforms, deterministic (no cargo).
  """
  use ExUnit.Case, async: true
  alias Nexus.Compilers.RustCli

  test "patch_section adds a [patch.crates-io] table redirecting a crate to a shim path" do
    toml = "[workspace]\nmembers = [\"a\"]\n"
    out = RustCli.patch_section(toml, [{"reqwest", "/abs/shims/reqwest"}])
    assert out =~ "[patch.crates-io]"
    assert out =~ ~s(reqwest = { path = "/abs/shims/reqwest" })
  end

  test "patch_section appends under an existing [patch.crates-io] table" do
    toml = "[patch.crates-io]\nfoo = { path = \"/x\" }\n"
    out = RustCli.patch_section(toml, [{"reqwest", "/abs/reqwest"}])
    # one table only, both entries present
    assert (out |> String.split("[patch.crates-io]") |> length()) == 2
    assert out =~ "foo = { path = \"/x\" }"
    assert out =~ ~s(reqwest = { path = "/abs/reqwest" })
  end

  test "trim_tokio rewrites features = [\"full\"] to the wasm-supported set" do
    toml = ~s(tokio = { version = "1", features = ["full"] }\n)
    out = RustCli.trim_tokio(toml)
    refute out =~ "full"
    assert out =~ ~s(features = ["rt", "macros", "sync", "io-util", "time"])
  end

  test "trim_tokio drops unsupported features (net/fs) from a mixed list" do
    toml = ~s(tokio = { version = "1", features = ["time", "fs", "net"] }\n)
    out = RustCli.trim_tokio(toml)
    refute out =~ "fs"
    refute out =~ "net"
    assert out =~ "io-util"
  end

  test "trim_tokio leaves non-tokio deps alone" do
    toml = ~s(serde = { version = "1", features = ["derive"] }\n)
    assert RustCli.trim_tokio(toml) == toml
  end

  test "rewrite_tokio_main adapts a bare entrypoint to current_thread (threadless wasm)" do
    assert RustCli.rewrite_tokio_main("#[tokio::main]\nasync fn main(){}") =~
             ~s|#[tokio::main(flavor = "current_thread")]|
    assert RustCli.rewrite_tokio_main("#[tokio::main()]\n") =~ "current_thread"
    # an explicit flavor is left as the author chose it
    explicit = ~s|#[tokio::main(flavor = "multi_thread")]\n|
    assert RustCli.rewrite_tokio_main(explicit) == explicit
  end

  test "prepare applies both transforms to a copy, leaving the source untouched" do
    src = Path.join(System.tmp_dir!(), "wb-cli-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Cargo.toml"), "[workspace]\nmembers = [\"app\"]\n")
    File.mkdir_p!(Path.join(src, "app"))
    File.write!(Path.join(src, "app/Cargo.toml"), ~s([package]\nname = "app"\n[dependencies]\ntokio = { version = "1", features = ["full"] }\nreqwest = "0.12"\n))

    dest = src <> "-prepared"
    {:ok, ^dest} = RustCli.prepare(src, dest, patch: [{"reqwest", "/shims/reqwest"}])

    # source untouched
    assert File.read!(Path.join(src, "app/Cargo.toml")) =~ "full"
    # workspace root got the patch table
    assert File.read!(Path.join(dest, "Cargo.toml")) =~ "[patch.crates-io]"
    # member tokio features trimmed
    refute File.read!(Path.join(dest, "app/Cargo.toml")) =~ "full"

    File.rm_rf(src)
    File.rm_rf(dest)
  end
end
