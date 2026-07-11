defmodule Nexus.PublishTest do
  @moduledoc """
  wb-jr1py.11 + wb-jr1py.13: the agent ship path. Authorization chain (identity → grant → facet →
  ownership → posture) each fail-closed with explicit reasons; the ship lane (export → R2 keys →
  worker upload with R2 binding + subdomain) exercised end-to-end with injected store + CF
  transports; edge seams dark ⇒ honest {:skip, _}.
  """
  use ExUnit.Case, async: false

  alias Nexus.Config

  defmodule StubS3 do
    def configured?, do: true

    def put(loc, key, bytes) do
      send(owner(), {:s3_put, loc, key, byte_size(bytes)})
      :ok
    end

    def owner, do: :persistent_term.get({__MODULE__, :owner})
    def own(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "publish-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "shop"))
    File.write!(Path.join(root, "index.work"), "# Manifest\n\ndeploy do\nend\n")

    File.write!(Path.join(root, "shop/index.work"), """
    # Shop

    facet app

    app :site do
      title "Shop"
      page "/", "home"
    end
    """)

    File.write!(Path.join(root, "shop/home.work"), "# Home\n\nHello shop.\n")
    File.mkdir_p!(Path.join(root, "corpus"))
    File.write!(Path.join(root, "corpus/index.work"), "# Corpus\n\nfacet kit\n")

    File.write!(Path.join(root, "agents.work"), """
    # Agents

    agent :keeper do
      prompt "runs the shop"
      manages "shop"
    end
    """)

    prev = %{
      asset_store: Config.asset_store(),
      asset_store_endpoint: Config.asset_store_endpoint(),
      asset_store_region: Config.asset_store_region(),
      cf_workers_subdomain: Config.cf_workers_subdomain()
    }

    Config.put(:asset_store, "s3://media/store")
    Config.put(:asset_store_endpoint, "https://acct.r2.cloudflarestorage.com")
    Config.put(:asset_store_region, "auto")
    Config.put(:cf_workers_subdomain, "wbtest")

    Application.put_env(:nexus, :publish_s3_client, StubS3)
    StubS3.own(self())

    on_exit(fn ->
      Enum.each(prev, fn {k, v} -> Config.put(k, v) end)
      Application.delete_env(:nexus, :publish_s3_client)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp perms(over \\ []) do
    Map.merge(
      %{agent: "keeper", grant: ["publish", "exec"], management: "managed", tenant: "t1"},
      Map.new(over)
    )
  end

  defp cf_ok(parent) do
    fn method, url, _h, body ->
      send(parent, {:cf, method, url, body})
      {:ok, {200, ~s({"success":true,"result":{"id":"ok"}})}}
    end
  end

  test "authorization chain refuses: identity, grant, facet, ownership, posture", %{root: root} do
    assert {:refused, r} = Nexus.Publish.publish(root, "shop", %{grant: ["publish"]})
    assert r =~ "agent identity"

    assert {:refused, r} = Nexus.Publish.publish(root, "shop", perms(grant: ["exec"]))
    assert r =~ "`publish` capability is not granted"

    assert {:refused, r} = Nexus.Publish.publish(root, "ghost", perms())
    assert r =~ ~s(no surface "ghost")

    assert {:refused, r} = Nexus.Publish.publish(root, "corpus", perms())
    assert r =~ "not a `facet app`"

    assert {:refused, r} = Nexus.Publish.publish(root, "shop", perms(agent: "rival"))
    assert r =~ "does not manage"

    assert {:refused, r} = Nexus.Publish.publish(root, "shop", perms(management: "frozen"))
    assert r =~ "frozen"

    assert {:refused, r} = Nexus.Publish.publish(root, "shop", perms(management: "proposed"))
    assert r =~ "request self publish shop"
  end

  test "unmanaged surface (no binding anywhere) is refused with the manages pointer", %{root: root} do
    File.write!(Path.join(root, "agents.work"), "# Agents\n")
    assert {:refused, r} = Nexus.Publish.publish(root, "shop", perms())
    assert r =~ ~s(declare `manages "shop"`)
  end

  test "authorized publish ships: R2 keys under apps/<tenant>/<surface>, worker with R2 binding + subdomain, url from config", %{root: root} do
    parent = self()

    assert {:ok, m} =
             Nexus.Publish.publish(root, "shop", perms(),
               cf_http: cf_ok(parent), cf_token: "cf", cf_account: "acct1")

    # bundle objects landed under the app prefix (index.html, 404.html, manifest, _headers at least)
    keys =
      for _ <- 1..m.assets do
        assert_receive {:s3_put, %{bucket: "media", prefix: "store"}, key, _}
        key
      end

    assert Enum.any?(keys, &(&1 == "apps/t1/shop/index.html"))
    assert Enum.any?(keys, &(&1 == "apps/t1/shop/404.html"))

    # worker uploaded with the R2 binding + served on workers.dev
    assert_receive {:cf, :put, worker_url, worker_body}
    assert worker_url =~ "/accounts/acct1/workers/scripts/wb-app-t1-shop"
    assert worker_body =~ ~s("bucket_name":"media")
    assert worker_body =~ "store/apps/t1/shop"
    assert_receive {:cf, :post, sub_url, sub_body}
    assert sub_url =~ "/workers/scripts/wb-app-t1-shop/subdomain"
    assert Jason.decode!(sub_body) == %{"enabled" => true}

    assert m.url == "https://wb-app-t1-shop.wbtest.workers.dev"
    assert m.mode == :static
    assert m.pages == 1
  end

  test "hybrid publish (--origin) bakes the proxy list into the worker", %{root: root} do
    parent = self()

    assert {:ok, m} =
             Nexus.Publish.publish(root, "shop", perms(),
               origin: "https://brain.fly.dev",
               cf_http: cf_ok(parent), cf_token: "cf", cf_account: "acct1")

    assert m.mode == :hybrid
    assert_receive {:cf, :put, _url, worker_body}
    assert worker_body =~ ~s(const ORIGIN = "https://brain.fly.dev")
    assert worker_body =~ ~s("/data")
    assert worker_body =~ ~s("/ws")
  end

  test "edge seams dark: no asset-store → skip; CF dark after store → skip with honest count", %{root: root} do
    Config.put(:asset_store, nil)
    assert {:skip, r} = Nexus.Publish.publish(root, "shop", perms())
    assert r =~ "no asset-store"

    Config.put(:asset_store, "s3://media/store")
    # no cf transport/token → Nexus.Cloudflare skips (token gate) after objects were stored
    assert {:skip, r2} = Nexus.Publish.publish(root, "shop", perms())
    assert r2 =~ "worker seam is dark"
    assert r2 =~ "stored"
  end
end
