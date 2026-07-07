defmodule Nexus.Net do
  @moduledoc """
  Shared outbound-HTTP hardening helpers.

  `:httpc.request/4` does NOT verify the server's TLS certificate unless you pass an explicit `ssl:`
  option — the default is effectively `verify_none`, so a MITM can present any cert and harvest the
  bearer key in the request headers (and inject a forged response). `tls_opts/0` returns the one
  correct `ssl` keyword list (peer verification against the OS trust store + hostname match) so every
  egress site can `Keyword.merge` it into its httpc opts instead of re-copying the block. See
  `Nexus.Net.Ssrf` for the complementary host-resolution egress guard.
  """

  @doc """
  The `ssl:` option list that makes `:httpc` actually verify the server certificate: peer verification
  against the OS trust store (`:public_key.cacerts_get/0`) plus HTTPS hostname matching. Merge into an
  httpc http-options list, e.g. `[timeout: 30_000] ++ Nexus.Net.tls_opts()`.
  """
  @spec tls_opts() :: keyword()
  def tls_opts do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end
end
