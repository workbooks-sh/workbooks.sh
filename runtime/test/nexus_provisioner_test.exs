defmodule Workbooks.NexusProvisionerTest do
  use ExUnit.Case, async: false

  alias Workbooks.NexusProvisioner
  alias Workbooks.NexusRegistry

  # A stub Fly client that records every call into an Agent and returns canned
  # success tuples — NO network. It also lets a test assert it was NEVER called
  # (the ownership-gate proof).
  defmodule StubFly do
    defp record(pid, call), do: Agent.update(pid, &[call | &1])

    # The Fly-client contract used by the provisioner. The owning Agent pid is passed
    # through opts[:stub] so each test gets its own recorder.
    def create_app(name, org, opts) do
      record(opts[:stub], {:create_app, name, org})
      {:ok, %{"name" => name}}
    end

    def create_machine(app, config, opts) do
      record(opts[:stub], {:create_machine, app, config})
      {:ok, %{"id" => "machine-" <> app}}
    end

    def start_machine(app, id, opts) do
      record(opts[:stub], {:start_machine, app, id})
      {:ok, %{"id" => id, "state" => "started"}}
    end

    def stop_machine(app, id, opts) do
      record(opts[:stub], {:stop_machine, app, id})
      {:ok, %{"id" => id, "state" => "stopped"}}
    end

    def destroy_machine(app, id, opts) do
      record(opts[:stub], {:destroy_machine, app, id})
      {:ok, %{}}
    end

    def delete_app(app, opts) do
      record(opts[:stub], {:delete_app, app})
      {:ok, %{}}
    end

    def get_machine(app, id, opts) do
      record(opts[:stub], {:get_machine, app, id})
      {:ok, %{"id" => id, "state" => "started"}}
    end
  end

  setup do
    prev_data = System.get_env("WB_DATA")
    prev_url = System.get_env("WB_DATABASE_URL")
    System.delete_env("WB_DATABASE_URL")
    dir = Path.join(System.tmp_dir!(), "nexus-prov-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", dir)

    {:ok, agent} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_url, do: System.put_env("WB_DATABASE_URL", prev_url)
      File.rm_rf(dir)
    end)

    h = NexusRegistry.open()
    # opts shared by every call: stub Fly client, pinned registry handle, and the
    # recorder Agent threaded through opts[:stub] (StubFly reads opts[:stub]).
    opts = [fly: StubFly, registry: h, stub: agent]
    {:ok, h: h, agent: agent, opts: opts}
  end

  defp calls(agent), do: agent |> Agent.get(&Enum.reverse(&1))

  test "provision registers a row and calls Fly with a config whose env has WB_TENANT + a per-nexus bearer",
       %{h: h, agent: agent, opts: opts} do
    assert {:ok, nexus} = NexusProvisioner.provision("org-a", opts)

    # Registered, org-scoped.
    assert {:ok, row} = NexusRegistry.get(nexus.id, "org-a", h)
    assert row.org_id == "org-a"
    assert row.fly_app == nexus.fly_app
    assert row.state == "created"
    assert nexus.url =~ nexus.fly_app

    # Fly client was driven: create_app then create_machine.
    cs = calls(agent)
    assert [{:create_app, app, _org}, {:create_machine, app2, config}] = cs
    assert app == nexus.fly_app
    assert app2 == nexus.fly_app

    env = config["env"]
    assert env["WB_TENANT"] == "org-a"
    assert is_binary(env["WB_PUBLIC_BEARER"]) and byte_size(env["WB_PUBLIC_BEARER"]) > 16
    # storage scoped to this tenant's prefix
    assert env["WB_S3_PREFIX"] == "tenants/org-a/"
    # scale-to-zero
    assert hd(config["services"])["autostop"] == "stop"
    assert hd(config["services"])["min_machines_running"] == 0
  end

  test "two provisions for two orgs get DISTINCT per-nexus bearers", %{agent: agent, opts: opts} do
    assert {:ok, _a} = NexusProvisioner.provision("org-a", opts)
    assert {:ok, _b} = NexusProvisioner.provision("org-b", opts)

    bearers =
      calls(agent)
      |> Enum.filter(&match?({:create_machine, _, _}, &1))
      |> Enum.map(fn {:create_machine, _app, config} -> config["env"]["WB_PUBLIC_BEARER"] end)

    assert length(bearers) == 2
    [a, b] = bearers
    assert a != b, "each nexus must get a fresh, isolated bearer"
  end

  test "database_url is passed per-nexus; nil omits WB_DATABASE_URL", %{agent: agent, opts: opts} do
    assert {:ok, _} = NexusProvisioner.provision("org-a", opts ++ [database_url: "postgres://x/y"])
    assert {:ok, _} = NexusProvisioner.provision("org-b", opts)

    machines =
      calls(agent)
      |> Enum.filter(&match?({:create_machine, _, _}, &1))
      |> Enum.map(fn {:create_machine, _app, config} -> config["env"] end)

    [a_env, b_env] = machines
    assert a_env["WB_DATABASE_URL"] == "postgres://x/y"
    refute Map.has_key?(b_env, "WB_DATABASE_URL")
  end

  test "the registry row stores NO secrets (bearer / DSN never persisted)", %{h: h, opts: opts} do
    assert {:ok, nexus} = NexusProvisioner.provision("org-a", opts ++ [database_url: "postgres://secret/dsn"])
    assert {:ok, row} = NexusRegistry.get(nexus.id, "org-a", h)

    serialized = inspect(row)
    refute serialized =~ "WB_PUBLIC_BEARER"
    refute serialized =~ "postgres://secret/dsn"
    # row carries only routing/identity metadata
    refute Map.has_key?(row, :bearer)
    refute Map.has_key?(row, :env)
  end

  test "the nexus id / app name does not encode the org (not forgeable across orgs)",
       %{opts: opts} do
    assert {:ok, nexus} = NexusProvisioner.provision("org-a", opts)
    refute nexus.id =~ "org-a"
    refute nexus.fly_app =~ "org-a"
  end

  # ── ownership gating: cross-org verbs take NO Fly action ──────────────────────────

  test "teardown is ownership-gated: cross-org → {:error,:not_found}, Fly never called",
       %{h: h, opts: opts} do
    assert {:ok, nexus} = NexusProvisioner.provision("org-a", opts)

    # fresh recorder so the provision calls don't pollute this assertion
    {:ok, gate} = Agent.start_link(fn -> [] end)
    gated = [fly: __MODULE__.StubFly, registry: h, stub: gate]

    assert {:error, :not_found} = NexusProvisioner.teardown(nexus.id, "org-b", gated)
    assert calls(gate) == [], "no Fly action on a cross-org teardown"
    # row is untouched — still owned by org-a
    assert {:ok, _} = NexusRegistry.get(nexus.id, "org-a", h)
  end

  test "wake / sleep / status are ownership-gated (cross-org → not_found, no Fly call)",
       %{h: h, opts: opts} do
    assert {:ok, nexus} = NexusProvisioner.provision("org-a", opts)

    {:ok, gate} = Agent.start_link(fn -> [] end)
    gated = [fly: __MODULE__.StubFly, registry: h, stub: gate]

    assert {:error, :not_found} = NexusProvisioner.wake(nexus.id, "org-b", gated)
    assert {:error, :not_found} = NexusProvisioner.sleep(nexus.id, "org-b", gated)
    assert {:error, :not_found} = NexusProvisioner.status(nexus.id, "org-b", gated)
    assert calls(gate) == [], "no Fly action on any cross-org lifecycle verb"
  end

  test "owned wake / sleep / teardown DO act and update state", %{h: h, agent: agent, opts: opts} do
    assert {:ok, nexus} = NexusProvisioner.provision("org-a", opts)

    assert {:ok, %{state: "running"}} = NexusProvisioner.wake(nexus.id, "org-a", opts)
    assert {:ok, %{state: "stopped"}} = NexusProvisioner.sleep(nexus.id, "org-a", opts)

    assert {:ok, :torn_down} = NexusProvisioner.teardown(nexus.id, "org-a", opts)
    # registry row gone after teardown
    assert {:error, :not_found} = NexusRegistry.get(nexus.id, "org-a", h)

    # the owned path DID drive Fly (start, stop, destroy all present)
    kinds = calls(agent) |> Enum.map(&elem(&1, 0))
    assert :start_machine in kinds
    assert :stop_machine in kinds
    assert :destroy_machine in kinds
  end

  test "provision with blank org fails closed, no Fly action", %{opts: opts, agent: agent} do
    assert {:error, :no_org} = NexusProvisioner.provision("", opts)
    assert {:error, :no_org} = NexusProvisioner.provision(nil, opts)
    assert calls(agent) == []
  end

  # ── FIX #1: org_id prefix-escape ─────────────────────────────────────────────────

  # Reproduce-then-fix: a malformed org_id would flow raw into WB_S3_PREFIX and
  # WB_TENANT, escaping the per-tenant prefix. Now rejected fail-closed, no Fly.
  test "provision refuses a malformed org_id (prefix-escape), no Fly action",
       %{opts: opts, agent: agent} do
    for bad <- ["a/../shared", "a/b", "", "x\ty", "a b", String.duplicate("x", 200)] do
      assert {:error, err} = NexusProvisioner.provision(bad, opts)
      assert err in [:invalid_org, :no_org]
    end

    assert calls(agent) == [], "no Fly action on a malformed org_id"
  end

  test "a normal org_id yields a WB_S3_PREFIX that cannot escape tenants/<org>/",
       %{agent: agent, opts: opts} do
    assert {:ok, _} = NexusProvisioner.provision("org-a", opts)

    [config] =
      calls(agent)
      |> Enum.filter(&match?({:create_machine, _, _}, &1))
      |> Enum.map(fn {:create_machine, _app, c} -> c end)

    prefix = config["env"]["WB_S3_PREFIX"]
    assert prefix == "tenants/org-a/"
    refute prefix =~ ".."
    refute config["env"]["WB_TENANT"] =~ "/"
  end

  # NexusRegistry.register also enforces the same rule directly (defense in depth).
  test "NexusRegistry.register rejects the same malformed org_ids", %{h: h} do
    for bad <- ["a/../shared", "a/b", "x\ty", String.duplicate("x", 200)] do
      assert {:error, _} = NexusRegistry.register(%{id: "nx-x", org_id: bad}, h)
    end

    assert {:ok, "nx-good"} = NexusRegistry.register(%{id: "nx-good", org_id: "org-a"}, h)
  end

  # ── FIX #2: orphan-cleanup on registry failure ───────────────────────────────────

  # A registry module that always fails register — proves provision tears the Fly
  # machine/app down rather than leaving a secret-bearing orphan.
  defmodule FailingRegistry do
    def open, do: :ignored_handle
    def register(_attrs, _h), do: {:error, :exists}
  end

  test "register failure → provision cleans up the Fly machine+app (no orphan)" do
    {:ok, gate} = Agent.start_link(fn -> [] end)
    opts = [fly: StubFly, registry_mod: FailingRegistry, stub: gate]

    assert {:error, :exists} = NexusProvisioner.provision("org-a", opts)

    kinds = gate |> Agent.get(&Enum.reverse(&1)) |> Enum.map(&elem(&1, 0))
    # the machine was created then destroyed, and the app deleted — nothing orphaned
    assert :create_machine in kinds
    assert :destroy_machine in kinds
    assert :delete_app in kinds
  end

  # ── FIX #3: fly_org pinned from server config, not caller opts ────────────────────

  test "provision uses the env/config fly_org, not an opts-supplied one",
       %{agent: agent, opts: opts} do
    prev = System.get_env("WB_FLY_ORG")
    System.put_env("WB_FLY_ORG", "trusted-org")
    on_exit(fn -> if prev, do: System.put_env("WB_FLY_ORG", prev), else: System.delete_env("WB_FLY_ORG") end)

    # caller tries to smuggle a different fly_org via opts — it must be IGNORED.
    assert {:ok, _} = NexusProvisioner.provision("org-a", opts ++ [fly_org: "attacker-org"])

    [{:create_app, _name, org}] =
      calls(agent) |> Enum.filter(&match?({:create_app, _, _}, &1))

    assert org == "trusted-org"
    refute org == "attacker-org"
  end
end
