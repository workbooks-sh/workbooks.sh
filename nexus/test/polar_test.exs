defmodule Nexus.PolarTest do
  use ExUnit.Case, async: false

  # ── config: server + product map come from the deploy block (our cloud's config, not baked) ──────
  test "polar config defaults: sandbox server, no products" do
    Nexus.Config.reload(nil)
    assert Nexus.Config.polar_server() == "sandbox"
    assert Nexus.Config.polar_products() == %{}
    assert Nexus.Config.polar_product("starter") == nil
    assert Nexus.Config.polar_credit_product() == nil
  after
    Nexus.Config.reload(nil)
  end

  test "polar config reads server + product UUIDs from the deploy block" do
    src = """
    deploy do
      polar-server="production"
      polar-product-starter="prod_starter_uuid"
      polar-product-team="prod_team_uuid"
      polar-credit-product="prod_credit_uuid"
    end
    """

    Nexus.Config.reload(src)
    assert Nexus.Config.polar_server() == "production"
    assert Nexus.Config.polar_product("starter") == "prod_starter_uuid"
    assert Nexus.Config.polar_product("team") == "prod_team_uuid"
    assert Nexus.Config.polar_product("scale") == nil
    assert Nexus.Config.polar_credit_product() == "prod_credit_uuid"
  after
    Nexus.Config.reload(nil)
  end

  # ── webhook verification: Standard Webhooks (svix) HMAC over `id.timestamp.body` ─────────────────
  test "verify_webhook accepts a correctly signed Standard-Webhooks payload" do
    key = :crypto.strong_rand_bytes(24)
    secret = "whsec_" <> Base.encode64(key)
    System.put_env("POLAR_WEBHOOK_SECRET", secret)

    id = "msg_123"
    ts = "1717000000"
    body = ~s({"type":"order.paid","data":{"metadata":{"tenant":"org_x"}}})
    sig = :crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}") |> Base.encode64()

    headers = %{"webhook-id" => id, "webhook-timestamp" => ts, "webhook-signature" => "v1,#{sig}"}
    assert Nexus.Polar.verify_webhook(body, headers) == true

    # a tampered body fails closed
    refute Nexus.Polar.verify_webhook(body <> "x", headers)
    # a missing signature header fails closed
    refute Nexus.Polar.verify_webhook(body, Map.delete(headers, "webhook-signature"))
  after
    System.delete_env("POLAR_WEBHOOK_SECRET")
  end

  test "verify_webhook fails closed with no secret configured" do
    System.delete_env("POLAR_WEBHOOK_SECRET")
    refute Nexus.Polar.verify_webhook("{}", %{"webhook-id" => "a", "webhook-timestamp" => "1", "webhook-signature" => "v1,zzz"})
  end

  test "create_checkout is :not_configured without a token" do
    System.delete_env("POLAR_ACCESS_TOKEN")
    assert Nexus.Polar.create_checkout(products: ["p"]) == {:error, :not_configured}
  end

  test "create_checkout rejects an empty product list" do
    System.put_env("POLAR_ACCESS_TOKEN", "polar_oat_test")
    assert Nexus.Polar.create_checkout(products: []) == {:error, :no_products}
  after
    System.delete_env("POLAR_ACCESS_TOKEN")
  end
end
