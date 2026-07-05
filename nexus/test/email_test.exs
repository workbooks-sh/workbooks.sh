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
end
