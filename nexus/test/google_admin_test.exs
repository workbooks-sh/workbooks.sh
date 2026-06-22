defmodule Nexus.Google.AdminTest do
  use ExUnit.Case, async: true
  alias Nexus.Google.Admin

  defp capture(reply) do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    http = fn method, url, headers, body ->
      Agent.update(agent, fn _ -> %{method: method, url: url, headers: headers, body: Jason.decode!(body)} end)
      reply
    end
    {agent, http}
  end

  test "create_user posts to the Directory users endpoint with a bearer token + name/email" do
    {agent, http} = capture({:ok, {200, Jason.encode!(%{"primaryEmail" => "agent@c.com"})}})

    assert {:ok, %{"primaryEmail" => "agent@c.com"}} =
             Admin.create_user("tok123", %{primary_email: "agent@c.com", given_name: "Work", family_name: "Bot"}, http: http)

    sent = Agent.get(agent, & &1)
    assert sent.method == :post
    assert sent.url == "https://admin.googleapis.com/admin/directory/v1/users"
    assert {"authorization", "Bearer tok123"} in sent.headers
    assert sent.body["primaryEmail"] == "agent@c.com"
    assert sent.body["name"]["givenName"] == "Work"
    assert is_binary(sent.body["password"]) and sent.body["password"] != ""
  end

  test "add_alias hits the per-user aliases endpoint" do
    {agent, http} = capture({:ok, {200, "{}"}})
    assert {:ok, _} = Admin.add_alias("tok", "agent@c.com", "proxy@c.com", http: http)
    sent = Agent.get(agent, & &1)
    assert sent.url == "https://admin.googleapis.com/admin/directory/v1/users/agent%40c.com/aliases"
    assert sent.body == %{"alias" => "proxy@c.com"}
  end

  test "add_send_as hits the Gmail settings endpoint" do
    {agent, http} = capture({:ok, {200, "{}"}})
    assert {:ok, _} = Admin.add_send_as("tok", "agent@c.com", "noreply@c.com", http: http)
    sent = Agent.get(agent, & &1)
    assert sent.url == "https://gmail.googleapis.com/gmail/v1/users/agent%40c.com/settings/sendAs"
    assert sent.body["sendAsEmail"] == "noreply@c.com"
  end

  test "add_domain_alias defaults the customer to my_customer" do
    {agent, http} = capture({:ok, {200, "{}"}})
    assert {:ok, _} = Admin.add_domain_alias("tok", nil, "agents.c.com", http: http)
    sent = Agent.get(agent, & &1)
    assert sent.url == "https://admin.googleapis.com/admin/directory/v1/customer/my_customer/domainaliases"
    assert sent.body == %{"domainAliasName" => "agents.c.com"}
  end

  test "non-2xx surfaces a structured error, not a crash" do
    {_agent, http} = capture({:ok, {403, Jason.encode!(%{"error" => %{"message" => "forbidden"}})}})
    assert {:error, {:google_http, 403, %{"error" => %{"message" => "forbidden"}}}} =
             Admin.add_alias("tok", "u@c.com", "a@c.com", http: http)
  end
end
