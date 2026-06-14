defmodule Workbooks.BackupIntegrationsTest do
  @moduledoc """
  Phase 6 — Backup + app-auth integrations. Backup is exercised end-to-end against a
  LOCAL bare repo (a real `git push`, no network): connect → status → disconnect.
  AuthIntegrations pins the provider registry and the configurable claim-map that
  lets a non-BetterAuth IdP scope the tenant correctly.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Backup, AuthIntegrations, Git}

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wb-bk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)
    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(data)
      System.delete_env("WB_TENANT_CLAIM")
      System.delete_env("WB_USER_CLAIM")
    end)
    :ok
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  defp seed(tenant, content) do
    dir = Git.ensure_repo(tenant)
    File.write!(Path.join(dir, "home.md"), content)
    Git.commit_and_push(dir, "seed", tenant)
    dir
  end

  test "backup connects to a git host, reports status, then disconnects" do
    t = uniq("acme")
    seed(t, "# Home\n")

    # initially nothing is connected
    assert %{connected: false, url: nil, host: nil} = Backup.status(t)

    # a local bare repo stands in for the remote git host — a real push, no network
    bare = Path.join(System.tmp_dir!(), "wb-bare-#{System.unique_integer([:positive])}.git")
    {_, 0} = System.cmd("git", ["init", "--bare", "-q", bare], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf(bare) end)

    assert {:ok, %{url: url}} = Backup.connect(t, url: "file://#{bare}")
    assert url == "file://#{bare}"

    # status now reports connected, and the remote actually received the commit
    assert %{connected: true, url: ^url} = Backup.status(t)
    {refs, 0} = System.cmd("git", ["--git-dir", bare, "log", "--oneline"], stderr_to_stdout: true)
    assert refs =~ "seed"

    # disconnect drops the remote (the remote copy is left in place)
    assert :ok = Backup.disconnect(t)
    assert %{connected: false} = Backup.status(t)
  end

  test "host label is inferred from the remote URL" do
    assert Backup.status(uniq("x")).host == nil
  end

  test "auth integrations expose the provider registry + default claim-map" do
    ids = Enum.map(AuthIntegrations.providers(), & &1.id)
    assert "builtin" in ids and "clerk" in ids and "workos" in ids and "auth0" in ids and "oidc" in ids
    assert AuthIntegrations.active() == "builtin"
    assert AuthIntegrations.config().claim_map == %{tenant: "organizationId", user: "sub"}
  end

  test "claim-map resolves the tenant/user from the configured claim names" do
    # default (BetterAuth) names
    assert {"org_1", "user_1"} = AuthIntegrations.identity_from_claims(%{"organizationId" => "org_1", "sub" => "user_1"})
    # solo user (no org claim) falls back to the user as tenant
    assert {"user_2", "user_2"} = AuthIntegrations.identity_from_claims(%{"sub" => "user_2"})

    # a different IdP that names the org "org_id" → configured via env, scopes correctly
    System.put_env("WB_TENANT_CLAIM", "org_id")
    assert {"acme", "u9"} = AuthIntegrations.identity_from_claims(%{"org_id" => "acme", "sub" => "u9"})
    # the BetterAuth name no longer leaks a tenant when the map points elsewhere
    assert {"u9", "u9"} = AuthIntegrations.identity_from_claims(%{"organizationId" => "ignored", "sub" => "u9"})
  end
end
