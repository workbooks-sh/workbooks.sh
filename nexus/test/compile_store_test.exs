defmodule Nexus.Compile.StoreTest do
  use ExUnit.Case, async: false
  alias Nexus.Compile.Store

  test "local-only mode: put then fetch round-trips through the configured dir" do
    Nexus.Config.reload(nil) # default component-cache = build/components (local)
    key = "storetest_#{System.unique_integer([:positive])}"
    src = Path.join(System.tmp_dir!(), "src_#{key}.wasm")
    File.write!(src, "BLOB")

    assert Store.fetch(key) == :miss
    lp = Store.put(key, src)
    assert String.contains?(lp, "build/components")
    assert {:ok, ^lp} = Store.fetch(key)
    assert File.read!(lp) == "BLOB"
    File.rm(lp)
  end

  test "an s3:// component-cache with no creds degrades to local (never errors a build)" do
    # Uses the deprecated `r2://` scheme to assert it still resolves as an alias of `s3://`.
    src = ~s(deploy do\n  component-cache="r2://bkt/components"\n  component-cache-endpoint="https://s3.example.com" component-cache-region="auto"\nend)
    Nexus.Config.reload(src)
    key = "storetest_#{System.unique_integer([:positive])}"
    src = Path.join(System.tmp_dir!(), "src2_#{key}.wasm")
    File.write!(src, "BLOB2")
    # No WB_S3_* creds in test → remote tier disabled, local hot dir used, no crash.
    assert Store.fetch(key) == :miss
    lp = Store.put(key, src)
    assert {:ok, ^lp} = Store.fetch(key)
    File.rm(lp)
  after
    Nexus.Config.reload(nil)
  end
end
