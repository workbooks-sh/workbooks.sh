defmodule Nexus.ControlPlaneEnvTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nexus.ControlPlane, as: CP

  # The env store holds SECRETS — these are adversarial: another org tries to see/reveal/mutate, the
  # list must never leak plaintext, the stored record must be ciphertext, and a missing master key
  # must fail closed (nothing stored). Routes are exercised over Plug.Test like platform_http_test.
  @opts Nexus.Platform.init([])
  # 32 zero bytes, base64 — a deterministic test master key.
  @master Base.encode64(:binary.copy(<<0>>, 32))

  defp call(method, path, org, body \\ nil) do
    c =
      if body do
        conn(method, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    c = if org, do: assign(c, :tenant, org), else: c
    Nexus.Platform.call(c, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  setup do
    System.put_env("WB_CONTROL_PLANE", "1")
    System.put_env("WB_ENV_MASTER_KEY", @master)
    CP.reset()
    prev = Application.get_env(:nexus, :auth)
    Application.put_env(:nexus, :auth, Nexus.Auth.Bearer) # non-None → multi? true

    on_exit(fn ->
      System.delete_env("WB_CONTROL_PLANE")
      System.delete_env("WB_ENV_MASTER_KEY")
      if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth)
    end)
  end

  defp create(org, name, value, extra \\ %{}) do
    c = call(:post, "/env", org, Map.merge(%{name: name, value: value, scope: "user"}, extra))
    assert c.status == 201
    body(c)
  end

  test "(a) org B cannot list / reveal / update / delete org A's env var even with the exact id" do
    a = create("org_env_a", "STRIPE_KEY", "sk_live_secret_a")
    id = a["id"]

    # B lists → never sees A's var
    b_list = call(:get, "/env", "org_env_b") |> body()
    refute Enum.any?(b_list["env"], &(&1["id"] == id)), "org B saw org A's env var — IDOR!"

    # B reveal / update / delete A's exact id → ownership-gated
    assert call(:get, "/env/#{id}/reveal", "org_env_b").status == 404
    assert call(:patch, "/env/#{id}", "org_env_b", %{value: "pwned"}).status == 404

    # B's delete is a no-op; A's var (and its true value) survive intact.
    assert call(:delete, "/env/#{id}", "org_env_b").status == 200
    reveal = call(:get, "/env/#{id}/reveal", "org_env_a")
    assert reveal.status == 200
    assert body(reveal)["value"] == "sk_live_secret_a"
  end

  test "(b) the LIST endpoint never returns a plaintext value" do
    create("org_env_l", "TOKEN", "super-secret-token-xyz")
    listing = call(:get, "/env", "org_env_l")
    row = body(listing)["env"] |> List.first()

    assert row["masked"] == "••••••••"
    assert row["length"] == byte_size("super-secret-token-xyz")
    refute Map.has_key?(row, "value")
    refute Map.has_key?(row, "ciphertext")
    refute listing.resp_body =~ "super-secret-token-xyz"
  end

  test "(c) reveal returns the exact value back for the owner" do
    v = create("org_env_r", "API_KEY", "the-exact-value-42")
    reveal = call(:get, "/env/#{v["id"]}/reveal", "org_env_r")
    assert reveal.status == 200
    assert body(reveal)["value"] == "the-exact-value-42"
  end

  test "(d) the stored DETS record holds ciphertext, not plaintext" do
    secret = "plaintext-must-not-persist"
    v = create("org_env_d", "SECRET", secret)
    {:ok, rec} = CP.get("org_env_d", :env, v["id"])

    refute inspect(rec) =~ secret, "plaintext leaked into the stored record!"
    assert is_binary(rec.ciphertext) and is_binary(rec.iv) and is_binary(rec.tag)
    refute Map.has_key?(rec, :value)
  end

  test "(e) with no WB_ENV_MASTER_KEY, create fails closed — nothing stored" do
    System.delete_env("WB_ENV_MASTER_KEY")
    c = call(:post, "/env", "org_env_nokey", %{name: "X", value: "y", scope: "user"})
    assert c.status == 503
    assert CP.list("org_env_nokey", :env) == []
  end

  test "(f) round-trip + same value twice yields different ciphertext (random IV)" do
    v1 = create("org_env_f", "DUP", "identical-value")
    v2 = create("org_env_f", "DUP2", "identical-value")

    # both reveal to the original
    assert body(call(:get, "/env/#{v1["id"]}/reveal", "org_env_f"))["value"] == "identical-value"
    assert body(call(:get, "/env/#{v2["id"]}/reveal", "org_env_f"))["value"] == "identical-value"

    {:ok, r1} = CP.get("org_env_f", :env, v1["id"])
    {:ok, r2} = CP.get("org_env_f", :env, v2["id"])
    refute r1.ciphertext == r2.ciphertext, "same plaintext produced identical ciphertext — IV reuse!"
    refute r1.iv == r2.iv
  end

  test "validation: bad name shape, bad scope, workspace scope without a workspace_id" do
    assert call(:post, "/env", "org_env_v", %{name: "1bad", value: "x", scope: "user"}).status == 422
    assert call(:post, "/env", "org_env_v", %{name: "OK", value: "x", scope: "nope"}).status == 422
    assert call(:post, "/env", "org_env_v", %{name: "OK", value: "x", scope: "workspace"}).status == 422

    ok = call(:post, "/env", "org_env_v", %{name: "OK", value: "x", scope: "workspace", workspace_id: "ws_1"})
    assert ok.status == 201
    assert body(ok)["workspace_id"] == "ws_1"
  end

  test "workspace filtering on the list endpoint" do
    create("org_env_w", "W1", "a", %{scope: "workspace", workspace_id: "ws_a"})
    create("org_env_w", "W2", "b", %{scope: "workspace", workspace_id: "ws_b"})

    only_a = call(:get, "/env?workspace=ws_a", "org_env_w") |> body()
    assert Enum.map(only_a["env"], & &1["name"]) == ["W1"]
  end

  test "update re-encrypts on a value change; reveal returns the new value" do
    v = create("org_env_u", "ROTATE", "old-value")
    {:ok, before} = CP.get("org_env_u", :env, v["id"])

    patched = call(:patch, "/env/#{v["id"]}", "org_env_u", %{value: "new-value"})
    assert patched.status == 200

    {:ok, aft} = CP.get("org_env_u", :env, v["id"])
    refute before.ciphertext == aft.ciphertext, "value change did not re-encrypt!"
    assert body(call(:get, "/env/#{v["id"]}/reveal", "org_env_u"))["value"] == "new-value"
  end

  test "scope=nexus filters the list to nexus-scoped secrets" do
    create("org_env_s", "NX", "a", %{scope: "nexus"})
    create("org_env_s", "WS", "b", %{scope: "workspace", workspace_id: "ws_a"})

    only_nx = call(:get, "/env?scope=nexus", "org_env_s") |> body()
    assert Enum.map(only_nx["env"], & &1["name"]) == ["NX"]
  end

  test "Env.value resolves a nexus-scoped secret by name and decrypts it" do
    create("org_env_val", "OPENROUTER_API_KEY", "sk-or-123", %{scope: "nexus"})
    # a workspace-scoped secret of the SAME name must NOT shadow the nexus lookup
    create("org_env_val", "OPENROUTER_API_KEY", "ws-decoy", %{scope: "workspace", workspace_id: "ws_x"})

    assert Nexus.ControlPlane.Env.value("org_env_val", "OPENROUTER_API_KEY") == {:ok, "sk-or-123"}
    assert Nexus.ControlPlane.Env.value("org_env_val", "NOPE") == {:error, :not_found}
  end

  test "Nexus.Secrets is store-first with an env fallback" do
    org = "org_secrets_seam"
    System.put_env("NEXUS_TENANT", org)
    System.put_env("SOME_ENV_ONLY", "from-env")
    System.put_env("OVERRIDE_ME", "env-loses")
    on_exit(fn -> Enum.each(~w(NEXUS_TENANT SOME_ENV_ONLY OVERRIDE_ME), &System.delete_env/1) end)

    create(org, "STORE_ONLY", "from-store", %{scope: "nexus"})
    create(org, "OVERRIDE_ME", "store-wins", %{scope: "nexus"})

    assert Nexus.Secrets.get("STORE_ONLY") == "from-store"   # store
    assert Nexus.Secrets.get("SOME_ENV_ONLY") == "from-env"  # env fallback (no store record)
    assert Nexus.Secrets.get("OVERRIDE_ME") == "store-wins"  # store-first beats env
    assert Nexus.Secrets.get("TOTALLY_UNSET") == nil
  end
end
