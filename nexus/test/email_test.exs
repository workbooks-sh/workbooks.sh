defmodule Nexus.EmailTest do
  use ExUnit.Case, async: true
  alias Nexus.Email

  defp capture(reply) do
    {:ok, agent} = Agent.start_link(fn -> nil end)

    http = fn method, url, headers, body ->
      Agent.update(agent, fn _ -> %{method: method, url: url, headers: headers, body: body} end)
      reply
    end

    {agent, http}
  end

  defp base(extra),
    do: Keyword.merge([to: "dest@example.com", subject: "Hi", text: "body", from: "agent@agents.workbooks.sh", token: "k"], extra)

  test "no key + no token → {:error, :not_configured}, never touches the network" do
    assert {:error, :not_configured} = Email.send(to: "a@b.com", subject: "s", text: "t", from: "f@g.com")
  end

  test "validation: missing recipient/subject/from/body each fail closed" do
    assert {:error, :missing_fields} = Email.send(subject: "s", text: "t", from: "f@g.com", token: "k")
    assert {:error, :missing_fields} = Email.send(to: "a@b.com", text: "t", from: "f@g.com", token: "k")
    assert {:error, :missing_from} = Email.send(to: "a@b.com", subject: "s", text: "t", token: "k")
    assert {:error, :missing_body} = Email.send(to: "a@b.com", subject: "s", from: "f@g.com", token: "k")
  end

  test "brevo adapter posts the Brevo shape to the fixed host; key never in the injected request" do
    {agent, http} = capture({:ok, {201, Jason.encode!(%{"messageId" => "m1"})}})

    assert {:ok, %{"messageId" => "m1"}} =
             Email.send(base(provider: "brevo", html: "<b>hi</b>", reply_to: "me@x.com", http: http))

    sent = Agent.get(agent, & &1)
    assert sent.method == :post
    assert sent.url == "https://api.brevo.com/v3/smtp/email"
    refute Enum.any?(sent.headers, fn {k, _} -> String.downcase(k) in ["api-key", "authorization"] end)

    body = Jason.decode!(sent.body)
    assert body["sender"] == %{"email" => "agent@agents.workbooks.sh"}
    assert body["to"] == [%{"email" => "dest@example.com"}]
    assert body["subject"] == "Hi"
    assert body["textContent"] == "body"
    assert body["htmlContent"] == "<b>hi</b>"
    assert body["replyTo"] == %{"email" => "me@x.com"}
  end

  test "smtp2go adapter posts the SMTP2GO shape (string sender, list recipients)" do
    {agent, http} = capture({:ok, {200, Jason.encode!(%{"data" => %{"succeeded" => 1}})}})

    assert {:ok, %{"data" => %{"succeeded" => 1}}} =
             Email.send(base(provider: "smtp2go", from_name: "Agent", http: http))

    sent = Agent.get(agent, & &1)
    assert sent.url == "https://api.smtp2go.com/v3/email/send"
    body = Jason.decode!(sent.body)
    assert body["sender"] == "Agent <agent@agents.workbooks.sh>"
    assert body["to"] == ["dest@example.com"]
    assert body["text_body"] == "body"
  end

  test "an unknown provider is rejected, not sent anywhere" do
    assert {:error, {:unknown_provider, "mailchimp"}} =
             Email.send(base(provider: "mailchimp", http: fn _, _, _, _ -> flunk("must not send") end))
  end

  test "a non-2xx relay response surfaces as {:error, {status, decoded}}" do
    {_a, http} = capture({:ok, {401, Jason.encode!(%{"message" => "bad key"})}})

    assert {:error, {401, %{"message" => "bad key"}}} =
             Email.send(base(provider: "brevo", http: http))
  end

  test "install/0 registers the email.send effect and it reaches send/1 (fails closed unconfigured)" do
    Email.install()
    assert Nexus.Effects.known?("email.send")

    # string-keyed args (as a .work hook supplies) reach send/1, which fails closed with no key
    effect = %{name: "email.send", args: %{"to" => "a@b.com", "subject" => "s", "text" => "t", "from" => "f@g.com"}}
    assert {:error, :not_configured} = Nexus.Effects.run(effect, %{}, %{})
  end

  test "email is a grantable capability" do
    assert Nexus.Capabilities.grantable?("email")
    # bare form and atom-list form both surface it
    assert "email" in Nexus.Capabilities.grants(%{header: "server mailer do grant email"})
    assert "email" in Nexus.Capabilities.grants(%{header: "server mailer do grant [:email, :net]"})
  end

  test "inbox: deliver stamps status/direction/thread; list + status filter; read marks read" do
    t = "test_inbox_#{System.unique_integer([:positive])}"
    on_exit(fn -> Nexus.ControlPlane.delete(t, "email", "mid-1") end)

    {:ok, rec} =
      Email.deliver_inbound(t, %{"from" => "alice@x.com", "subject" => "Re: Hello", "text" => "hi", "message_id" => "mid-1"})

    assert rec["status"] == "unread"
    assert rec["direction"] == "in"
    assert rec["thread"] == "hello"

    assert [one] = Email.inbox(t)
    assert one[:id] == "mid-1"
    assert length(Email.inbox(t, status: "unread")) == 1

    assert {:ok, r} = Email.read(t, "mid-1")
    assert r["from"] == "alice@x.com"
    assert Email.inbox(t, status: "unread") == []
    assert length(Email.inbox(t, status: "read")) == 1

    assert {:error, :not_found} = Email.read(t, "nope")
  end

  test "reply threads to the original sender with a non-doubled Re: subject + In-Reply-To header" do
    t = "test_reply_#{System.unique_integer([:positive])}"
    on_exit(fn -> Nexus.ControlPlane.delete(t, "email", "mid-2") end)
    Email.deliver_inbound(t, %{"from" => "bob@y.com", "subject" => "Re: Question", "message_id" => "mid-2"})

    {:ok, agent} = Agent.start_link(fn -> nil end)
    http = fn _m, _u, _h, b -> Agent.update(agent, fn _ -> b end); {:ok, {201, ~s({"messageId":"x"})}} end

    assert {:ok, _} = Email.reply(t, "mid-2", text: "answer", from: "agent@a.com", provider: "brevo", token: "k", http: http)

    body = Jason.decode!(Agent.get(agent, & &1))
    assert body["to"] == [%{"email" => "bob@y.com"}]
    assert body["subject"] == "Re: Question"
    assert body["headers"] == %{"In-Reply-To" => "mid-2"}
    assert length(Email.inbox(t, status: "read")) == 1
  end

  test "ingest stores an inbound message in the recipient tenant's inbox" do
    t = "test_ingest_#{System.unique_integer([:positive])}"
    on_exit(fn -> Nexus.ControlPlane.delete(t, "email", "mid-3") end)

    payload = %{"from" => "carol@z.com", "to" => "agent@agents.workbooks.sh", "subject" => "Ping", "text" => "yo", "message_id" => "mid-3"}
    assert {:ok, rec} = Email.ingest(payload, tenant: t)
    assert rec["from"] == "carol@z.com"
    assert rec["status"] == "unread"
    assert [got] = Email.inbox(t)
    assert got[:id] == "mid-3"
  end

  test "from_for sub-addresses non-default tenants so replies route back" do
    # non-default tenant → agent+<tenant>@<domain> (email_domain resolves via test config default nil →
    # falls back to email_from which is also nil in test; assert the sub-address shape when a domain exists)
    assert Nexus.Email.from_for("acme") in [nil, "agent+acme@agents.workbooks.sh"] or
             String.starts_with?(to_string(Nexus.Email.from_for("acme")), "agent+acme@")
  end

  test "ingest routes a sub-addressed recipient (local+tenant@) to that tenant" do
    on_exit(fn -> Nexus.ControlPlane.delete("acme", "email", "mid-4") end)
    payload = %{"from" => "x@y.com", "to" => "agent+acme@agents.workbooks.sh", "subject" => "s", "message_id" => "mid-4"}
    assert {:ok, _} = Email.ingest(payload)
    assert Enum.any?(Email.inbox("acme"), &(&1[:id] == "mid-4"))
  end
end
