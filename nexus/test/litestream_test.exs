defmodule Nexus.LitestreamTest do
  use ExUnit.Case, async: false

  alias Nexus.Litestream

  # These secrets are read from the process env via Nexus.Secrets — set/clear around each test.
  @s3 ~w(WB_S3_BUCKET WB_S3_ACCESS_KEY_ID WB_S3_SECRET_ACCESS_KEY WB_S3_ENDPOINT WB_S3_REGION WB_S3_PREFIX
         BUCKET_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL_S3 AWS_REGION)

  setup do
    saved = Map.new(@s3, &{&1, System.get_env(&1)})
    Enum.each(@s3, &System.delete_env/1)
    on_exit(fn -> Enum.each(saved, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end) end)
    :ok
  end

  test "db_path lives under a hidden .nexus dir so the static tier can't serve it" do
    assert Litestream.db_path() |> Path.split() |> Enum.member?(".nexus")
    assert String.ends_with?(Litestream.db_path(), "nexus.db")
  end

  test "disabled with no S3 secrets; no replica, write_config refuses" do
    refute Litestream.enabled?()
    assert Litestream.replica() == nil
    assert {:error, :no_replica} = Litestream.write_config(Path.join(System.tmp_dir!(), "x.yml"))
  end

  test "enabled once bucket + key are injected; replica derives from secrets" do
    System.put_env("WB_S3_BUCKET", "my-bucket")
    System.put_env("WB_S3_ACCESS_KEY_ID", "AKID")
    System.put_env("WB_S3_SECRET_ACCESS_KEY", "secret")
    System.put_env("WB_S3_ENDPOINT", "https://acct.r2.cloudflarestorage.com")
    System.put_env("WB_S3_PREFIX", "tenant42")

    assert Litestream.enabled?()
    rep = Litestream.replica()
    assert rep.type == "s3"
    assert rep.bucket == "my-bucket"
    assert rep.endpoint == "https://acct.r2.cloudflarestorage.com"
    assert rep.region == "auto"
    # object path namespaced under prefix + litestream/, no leading slash
    assert rep.path == "tenant42/litestream/nexus.db"
  end

  test "generated config omits secret keys (passed via LITESTREAM_* env, never written)" do
    System.put_env("WB_S3_BUCKET", "b")
    System.put_env("WB_S3_ACCESS_KEY_ID", "AKID-should-not-appear")
    System.put_env("WB_S3_SECRET_ACCESS_KEY", "SECRET-should-not-appear")
    System.put_env("WB_S3_ENDPOINT", "https://e")

    yaml = Litestream.config_yaml()
    assert yaml =~ "type: s3"
    assert yaml =~ "bucket: b"
    refute yaml =~ "AKID-should-not-appear"
    refute yaml =~ "SECRET-should-not-appear"
    refute yaml =~ "access-key"
  end

  test "file-replica config form (used by the validation harness)" do
    yaml = Litestream.config_yaml(%{type: "file", path: "/tmp/replica"}, "/tmp/db/nexus.db")
    assert yaml =~ "path: /tmp/db/nexus.db"
    assert yaml =~ "type: file"
    assert yaml =~ "path: /tmp/replica"
  end
end
