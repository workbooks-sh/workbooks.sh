defmodule Workbooks.Auth.JWKS do
  @moduledoc """
  JWKS resolver for the RS256 prod auth path (AUTH.org). Fetches a BetterAuth
  JWKS endpoint (GET /api/auth/jwks), caches the key set, and selects the JWK
  matching a token's `kid` — returned as a `JOSE.JWK` for Guardian to verify
  against. HTTP is built-in `:httpc` (no new dep); the cache is `persistent_term`
  with a TTL.

  `seed/2` pre-loads a key set without a network call — used to preload from a
  known gateway and to drive tests with a generated keypair (no live gateway).
  """
  @ttl_ms 5 * 60 * 1000

  @doc "A JOSE.JWK to verify a token from `url`, by `kid` (or the first key)."
  def key(url, kid \\ nil), do: select(keys(url), kid)

  @doc "Pre-load a JWKS key list (list of JWK maps) for `url`, bypassing fetch."
  def seed(url, key_maps), do: :persistent_term.put(ckey(url), {key_maps, now() + @ttl_ms})

  defp keys(url) do
    case :persistent_term.get(ckey(url), nil) do
      {keys, exp} -> if now() < exp, do: keys, else: fetch_and_cache(url)
      nil -> fetch_and_cache(url)
    end
  end

  defp fetch_and_cache(url) do
    keys = fetch(url)
    :persistent_term.put(ckey(url), {keys, now() + @ttl_ms})
    keys
  end

  defp fetch(url) do
    :inets.start()
    :ssl.start()
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    Jason.decode!(body)["keys"]
  end

  defp select(keys, nil), do: JOSE.JWK.from(hd(keys))

  defp select(keys, kid) do
    (Enum.find(keys, &(&1["kid"] == kid)) || hd(keys)) |> JOSE.JWK.from()
  end

  defp ckey(url), do: {__MODULE__, url}
  defp now, do: System.monotonic_time(:millisecond)
end
