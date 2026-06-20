defmodule Nexus.Auth.Email do
  @moduledoc """
  Transactional auth email via **Resend** (verification + password reset). One generic seam, keyed by
  the injected `RESEND_API_KEY` secret (THE LINE: the provider is config, no key in source). With no
  key configured (dev), it **logs the link** instead of sending — so the flow works end to end offline.

  The `from` address is `WB_EMAIL_FROM` (a verified Resend sender, e.g. `Workbooks
  <noreply@workbooks.sh>`); defaults to Resend's `onboarding@resend.dev` test sender until the domain
  is verified. Uses OTP-native `:httpc` — no HTTP dep.
  """
  require Logger

  @endpoint ~c"https://api.resend.com/emails"

  @doc "Email a sign-in verification link."
  def send_verification(to, link) do
    deliver(to, "Verify your Workbooks email",
      body("Confirm your email", "Click below to verify your address and finish signing in.", "Verify email", link))
  end

  @doc "Email a password-reset link."
  def send_reset(to, link) do
    deliver(to, "Reset your Workbooks password",
      body("Reset your password", "We got a request to reset your password. This link expires in an hour. If it wasn't you, ignore this.", "Reset password", link))
  end

  @doc "Send `html` to `to`. `{:ok, id} | {:error, reason}`. No key ⇒ logs the link (dev), returns `{:ok, :logged}`."
  def deliver(to, subject, html) do
    case Nexus.Secrets.get("RESEND_API_KEY") do
      nil ->
        Logger.info("[auth.email] (no RESEND_API_KEY) would send to #{to}: #{subject}")
        # Surface the link in dev logs so the flow is testable without a provider.
        for [_, url] <- Regex.scan(~r/href="([^"]+)"/, html), do: Logger.info("[auth.email] link → #{url}")
        {:ok, :logged}

      key ->
        payload = Jason.encode!(%{from: from(), to: [to], subject: subject, html: html})

        req =
          {@endpoint, [{~c"authorization", ~c"Bearer " ++ String.to_charlist(key)}], ~c"application/json",
           payload}

        case :httpc.request(:post, req, [{:timeout, 10_000}], []) do
          {:ok, {{_, status, _}, _h, resp}} when status in 200..299 ->
            {:ok, to_string(resp)}

          {:ok, {{_, status, _}, _h, resp}} ->
            Logger.error("[auth.email] resend #{status}: #{to_string(resp)}")
            {:error, {:resend, status}}

          {:error, reason} ->
            Logger.error("[auth.email] resend transport error: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp from, do: Nexus.Secrets.get("WB_EMAIL_FROM", "Workbooks <onboarding@resend.dev>")

  defp body(heading, lede, cta, link) do
    """
    <div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:460px;margin:0 auto;padding:32px 24px;color:#16161a">
      <h1 style="font-size:20px;font-weight:700;margin:0 0 12px">#{heading}</h1>
      <p style="font-size:14px;line-height:1.6;color:#4a4f48;margin:0 0 24px">#{lede}</p>
      <a href="#{link}" style="display:inline-block;background:#16161a;color:#fff;text-decoration:none;font-weight:600;font-size:14px;padding:12px 22px;border-radius:10px">#{cta}</a>
      <p style="font-size:12px;color:#a4a097;margin:24px 0 0">or paste this link:<br><span style="word-break:break-all">#{link}</span></p>
    </div>
    """
  end
end
