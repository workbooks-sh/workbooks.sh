defmodule Workbooks.Auth.SecretFetcher do
  @moduledoc """
  Guardian secret resolver. The `secret_key` MFA can't see the incoming token,
  so per-`kid` JWKS selection needs a SecretFetcher — it's handed the token
  headers. When `WB_JWKS_URL` is set we verify RS256 against the BetterAuth JWKS
  (key chosen by the token's `kid`); otherwise we fall back to the default
  (HS256 `secret_key`) for local testing. Signing always uses the default.
  """
  use Guardian.Token.Jwt.SecretFetcher
  alias Guardian.Token.Jwt.SecretFetcher.SecretFetcherDefaultImpl

  # Overrides the default impl provided by `use` (which has no @behaviour to @impl).
  def fetch_verifying_secret(mod, token_headers, opts) do
    case System.get_env("WB_JWKS_URL") do
      url when is_binary(url) -> {:ok, Workbooks.Auth.JWKS.key(url, token_headers["kid"])}
      _ -> SecretFetcherDefaultImpl.fetch_verifying_secret(mod, token_headers, opts)
    end
  end
end
