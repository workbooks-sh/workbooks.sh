defmodule Workbooks.AuthBrokerTest do
  @moduledoc """
  The sign-in broker is a PUBLIC, unauthenticated surface — these lock its security
  floors so they can't silently regress: loopback-only redirects (no open redirector),
  PKCE-shaped challenges, and one-time/unknown-code rejection on exchange.
  """
  use ExUnit.Case, async: false

  setup do
    prev = System.get_env("WORKOS_API_KEY")
    System.put_env("WORKOS_API_KEY", "sk_test_dummy")
    System.put_env("WB_OIDC_JWKS_URL", "https://api.workos.com/sso/jwks/client_01TEST")
    unless Process.whereis(Workbooks.AuthBroker), do: start_supervised!(Workbooks.AuthBroker)
    on_exit(fn -> if prev, do: System.put_env("WORKOS_API_KEY", prev), else: System.delete_env("WORKOS_API_KEY") end)
    :ok
  end

  @good_challenge String.duplicate("a", 43)

  test "rejects a non-loopback redirect (no open redirector)" do
    assert {:error, :bad_redirect} =
             Workbooks.AuthBroker.begin_authorize("https://evil.example.com/cb", @good_challenge)
  end

  test "rejects a redirect that isn't http loopback" do
    for uri <- ["https://127.0.0.1/cb", "http://169.254.169.254/cb", "ftp://127.0.0.1/cb", ""] do
      assert {:error, :bad_redirect} = Workbooks.AuthBroker.begin_authorize(uri, @good_challenge)
    end
  end

  test "rejects a malformed PKCE challenge" do
    for bad <- ["short", "has spaces!!", String.duplicate("a", 1000)] do
      assert {:error, :bad_challenge} =
               Workbooks.AuthBroker.begin_authorize("http://127.0.0.1:5000/cb", bad)
    end
  end

  test "accepts a loopback redirect + valid challenge and returns an AuthKit URL" do
    assert {:ok, url} =
             Workbooks.AuthBroker.begin_authorize("http://127.0.0.1:5000/cb", @good_challenge)

    assert url =~ "api.workos.com/user_management/authorize"
    assert url =~ "provider=authkit"
    assert url =~ "client_01TEST"
  end

  test "exchange rejects an unknown / already-used code" do
    assert {:error, :unknown_code} = Workbooks.AuthBroker.exchange("nope", "verifier")
  end

  test "callback rejects an unknown state" do
    assert {:error, :unknown_state} = Workbooks.AuthBroker.complete_callback("wcode", "ststate")
  end
end
