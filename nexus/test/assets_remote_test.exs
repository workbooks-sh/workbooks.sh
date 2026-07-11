defmodule Nexus.AssetsRemoteTest do
  @moduledoc """
  wb-jr1py.4: Nexus.Assets remote tier — write-through to the `asset-store` object store, public-url
  handout when `asset-store-public` is declared, remote fallback + rematerialize on local read miss,
  and graceful degrade (upload failure ⇒ local serving, never an error).
  """
  use ExUnit.Case, async: false

  alias Nexus.Config

  defmodule StubS3 do
    def configured?, do: true

    def put(loc, key, bytes) do
      send(test_pid(), {:s3_put, loc, key, bytes})

      case :persistent_term.get({__MODULE__, :put_result}, :ok) do
        :ok -> :ok
        err -> err
      end
    end

    def get(loc, key) do
      send(test_pid(), {:s3_get, loc, key})
      :persistent_term.get({__MODULE__, :get_result}, {:error, :not_found})
    end

    def put_result(v), do: :persistent_term.put({__MODULE__, :put_result}, v)
    def get_result(v), do: :persistent_term.put({__MODULE__, :get_result}, v)
    def owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    defp test_pid, do: :persistent_term.get({__MODULE__, :owner})
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "assets-remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_data = System.get_env("WB_DATA")
    System.put_env("WB_DATA", tmp)

    prev = %{
      asset_store: safe_get(:asset_store),
      asset_store_endpoint: safe_get(:asset_store_endpoint),
      asset_store_region: safe_get(:asset_store_region),
      asset_store_public: safe_get(:asset_store_public)
    }

    Application.put_env(:nexus, :assets_s3_client, StubS3)
    StubS3.owner(self())
    StubS3.put_result(:ok)
    StubS3.get_result({:error, :not_found})

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      Application.delete_env(:nexus, :assets_s3_client)
      Enum.each(prev, fn {k, v} -> Config.put(k, v) end)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp safe_get(key) do
    apply(Config, key, [])
  rescue
    _ -> nil
  end

  defp configure(store, public \\ nil) do
    Config.put(:asset_store, store)
    Config.put(:asset_store_endpoint, "https://acct.r2.cloudflarestorage.com")
    Config.put(:asset_store_region, "auto")
    Config.put(:asset_store_public, public)
  end

  test "no asset-store ⇒ pure local (regression): local url, no S3 traffic", %{tmp: tmp} do
    configure(nil)
    {:ok, a} = Nexus.Assets.put("t1", "png-bytes", "image/png")
    assert a.url == "/assets/t1/#{a.name}"
    assert File.read!(Path.join([tmp, "assets", "t1", a.name])) == "png-bytes"
    refute_receive {:s3_put, _, _, _}
  end

  test "write-through: upload happens, bucket/prefix parsed, key is tenant-scoped" do
    configure("s3://media/assets")
    {:ok, a} = Nexus.Assets.put("t1", "bytes", "image/png")
    assert_receive {:s3_put, loc, key, "bytes"}
    assert %{bucket: "media", prefix: "assets", region: "auto"} = loc
    assert key == "t1/#{a.name}"
    # no public base ⇒ still the local url (S3 copy is durability, not serving)
    assert a.url == "/assets/t1/#{a.name}"
  end

  test "public base declared ⇒ put hands out the edge url (prefix included)" do
    configure("s3://media/assets", "https://cdn.example.com/")
    {:ok, a} = Nexus.Assets.put("t1", "bytes", "image/webp")
    assert a.url == "https://cdn.example.com/assets/t1/#{a.name}"
  end

  test "r2:// deprecated alias still parses" do
    configure("r2://media")
    {:ok, a} = Nexus.Assets.put("t2", "b", "image/gif")
    assert_receive {:s3_put, %{bucket: "media", prefix: ""}, key, "b"}
    assert key == "t2/#{a.name}"
  end

  test "upload failure degrades to local url, put still succeeds" do
    configure("s3://media/assets", "https://cdn.example.com")
    StubS3.put_result({:error, :timeout})
    {:ok, a} = Nexus.Assets.put("t1", "bytes", "image/png")
    assert a.url == "/assets/t1/#{a.name}"
  end

  test "read: local miss falls back to remote and rematerializes", %{tmp: tmp} do
    configure("s3://media/assets")
    StubS3.get_result({:ok, "remote-bytes"})
    assert {:ok, "remote-bytes", "image/png"} = Nexus.Assets.read("t9", "abc.png")
    assert_receive {:s3_get, _, "t9/abc.png"}
    # rematerialized: second read is local (no further S3 traffic)
    assert File.read!(Path.join([tmp, "assets", "t9", "abc.png"])) == "remote-bytes"
    assert {:ok, "remote-bytes", "image/png"} = Nexus.Assets.read("t9", "abc.png")
    refute_receive {:s3_get, _, _}
  end

  test "read: local + remote miss stays :error" do
    configure("s3://media/assets")
    assert :error = Nexus.Assets.read("t9", "missing.png")
  end
end
