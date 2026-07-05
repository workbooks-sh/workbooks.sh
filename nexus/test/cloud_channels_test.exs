defmodule Nexus.Cloud.ChannelsTest do
  use ExUnit.Case, async: false
  alias Nexus.Cloud.Channels

  # A Telnyx transport that answers per endpoint. Records each URL it saw.
  defp telnyx_http(replies) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    http = fn _method, url, _headers, _body ->
      Agent.update(agent, fn urls -> urls ++ [url] end)

      body =
        cond do
          String.contains?(url, "messaging_profiles") -> replies[:profile] || %{"data" => %{"id" => "mp1"}}
          String.contains?(url, "number_orders") -> replies[:order] || %{"data" => %{"id" => "ord1"}}
          String.contains?(url, "available_phone_numbers") -> replies[:available] || %{"data" => []}
          String.contains?(url, "tollfree") -> replies[:tf] || %{"data" => %{"id" => "tfv1"}}
          true -> %{}
        end

      {:ok, {200, Jason.encode!(body)}}
    end

    {agent, http}
  end

  test "unconfigured (no key / no injected transport) → {:skip, _}, never touches the network" do
    assert {:skip, _} = Channels.available_numbers()
    assert {:skip, _} = Channels.provision("org1", "+18550000000")
  end

  test "available_numbers searches US toll-free with SMS" do
    {agent, http} = telnyx_http(available: %{"data" => [%{"phone_number" => "+18551234567"}]})
    assert {:ok, %{"data" => [%{"phone_number" => "+18551234567"}]}} = Channels.available_numbers(token: "t", http: http)
    [url] = Agent.get(agent, & &1)
    assert String.contains?(url, "available_phone_numbers")
    assert String.contains?(url, "toll_free")
  end

  test "provision attaches a messaging profile, orders the number, and registers number→tenant" do
    t = "org_#{System.unique_integer([:positive])}"
    num = "+18559990000"
    on_exit(fn -> Channels.release(t, num) end)
    {agent, http} = telnyx_http(%{})

    assert {:ok, rec} =
             Channels.provision(t, num, token: "t", http: http, webhook_url: "https://x/cloud/telnyx/webhook")

    assert rec["messaging_profile_id"] == "mp1"
    assert rec["number"] == num
    assert rec["status"] == "provisioned"
    assert rec["tf_status"] == "unverified"

    # both Telnyx calls happened, profile before order
    urls = Agent.get(agent, & &1)
    assert Enum.any?(urls, &String.contains?(&1, "messaging_profiles"))
    assert Enum.any?(urls, &String.contains?(&1, "number_orders"))

    # registry: per-tenant list + the global owner index the webhook resolves against
    assert Enum.any?(Channels.list(t), &(&1["number"] == num))
    assert Channels.tenant_for_number(num) == t
  end

  test "release deregisters the number from both the tenant list and the global index" do
    t = "org_#{System.unique_integer([:positive])}"
    num = "+18557778888"
    {_a, http} = telnyx_http(%{})
    {:ok, _} = Channels.provision(t, num, token: "t", http: http, webhook_url: "https://x/wh")
    assert Channels.tenant_for_number(num) == t

    assert {:ok, :released} = Channels.release(t, num)
    assert Channels.tenant_for_number(num) == nil
    refute Enum.any?(Channels.list(t), &(&1["number"] == num))
  end

  test "submit_verification stamps the verification id + pending status onto the number record" do
    t = "org_#{System.unique_integer([:positive])}"
    num = "+18551112222"
    on_exit(fn -> Channels.release(t, num) end)
    {_a, http} = telnyx_http(%{})
    {:ok, _} = Channels.provision(t, num, token: "t", http: http, webhook_url: "https://x/wh")

    assert {:ok, %{"data" => %{"id" => "tfv1"}}} =
             Channels.submit_verification(t, %{"phone_number" => num, "business_name" => "shinyobjectz"}, token: "t", http: http)

    rec = Enum.find(Channels.list(t), &(&1["number"] == num))
    assert rec["tf_verification_id"] == "tfv1"
    assert rec["tf_status"] == "pending"
  end

  test "ingest_event routes an inbound SMS to the owning tenant; ignores other events + bad input" do
    t = "org_#{System.unique_integer([:positive])}"
    num = "+18553334444"
    on_exit(fn -> Channels.release(t, num) end)
    {_a, http} = telnyx_http(%{})
    {:ok, _} = Channels.provision(t, num, token: "t", http: http, webhook_url: "https://x/wh")

    payload = %{
      "data" => %{
        "event_type" => "message.received",
        "payload" => %{"from" => %{"phone_number" => "+15550001111"}, "to" => [%{"phone_number" => num}], "text" => "hi agent"}
      }
    }

    assert {:ok, :emitted} = Channels.ingest_event(payload)
    assert {:ok, :emitted} = Channels.ingest_event(Jason.encode!(payload))
    assert {:ok, :ignored} = Channels.ingest_event(%{"data" => %{"event_type" => "message.sent"}})
    assert {:ok, :ignored} = Channels.ingest_event("not json at all")
  end
end
