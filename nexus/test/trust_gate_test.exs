defmodule Nexus.TrustGateTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Nexus.Trust

  # wb-rh95 — native-BEAM kinds (server/worker/def/hook/test/auth) authored in an UNTRUSTED workspace
  # must never compile to native Elixir on the host. WASM kinds (client/sandbox) and data (resource)
  # are always allowed.

  describe "Trust pure logic" do
    test "native_kind? covers the BEAM kinds, not wasm/data" do
      for k <- ~w(server worker def hook test auth), do: assert(Trust.native_kind?(k))
      for k <- ~w(client sandbox resource flow agent check toolkit), do: refute(Trust.native_kind?(k))
    end

    test "untrusted_path? matches a subtree prefix (equal or nested)" do
      u = ["tenants", "site/guest"]
      assert Trust.untrusted_path?("tenants/evil.work", u)
      assert Trust.untrusted_path?("tenants/a/b.work", u)
      assert Trust.untrusted_path?("site/guest/x.work", u)
      assert Trust.untrusted_path?("./tenants/evil.work", u)
      refute Trust.untrusted_path?("app/main.work", u)
      refute Trust.untrusted_path?("tenants-internal/x.work", u)  # prefix must be a path boundary
      refute Trust.untrusted_path?("anything.work", [])
    end

    test "gate rejects native kinds from untrusted paths only" do
      u = ["tenants"]
      assert Trust.gate("server", "tenants/x.work", u) == {:error, {:untrusted_native_kind, "server", "tenants/x.work"}}
      assert Trust.gate("worker", "tenants/x.work", u) == {:error, {:untrusted_native_kind, "worker", "tenants/x.work"}}
      assert Trust.gate("client", "tenants/x.work", u) == :ok   # wasm kind allowed even untrusted
      assert Trust.gate("server", "app/x.work", u) == :ok        # trusted subtree
    end

    test "partition splits allowed vs rejected" do
      Nexus.Config.put(:untrusted_workspaces, ["tenants"])
      on_exit(fn -> Nexus.Config.put(:untrusted_workspaces, []) end)

      pairs = [
        {%{kind: "server", name: "ok"}, "app/a.work"},
        {%{kind: "server", name: "evil"}, "tenants/b.work"},
        {%{kind: "client", name: "ui"}, "tenants/c.work"}
      ]

      {allowed, rejected} = Trust.partition(pairs)
      assert Enum.map(allowed, & &1.name) == ["ok", "ui"]
      assert [{_, "tenants/b.work", {:untrusted_native_kind, "server", _}}] = rejected
    end
  end

  describe "compile_workbook enforcement (end-to-end)" do
    setup do
      Nexus.Config.put(:untrusted_workspaces, ["tenants"])
      on_exit(fn -> Nexus.Config.put(:untrusted_workspaces, []) end)
      root = Path.join(System.tmp_dir!(), "trust_wb_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "app"))
      File.mkdir_p!(Path.join(root, "tenants"))
      File.write!(Path.join(root, "app/main.work"), "Trusted.\n\nserver :alpha do\n  def hi, do: :ok\nend\n")
      File.write!(Path.join(root, "tenants/evil.work"), "Tenant.\n\nserver :evilsvc do\n  def pwn, do: System.cmd(\"sh\", [\"-c\", \"id\"])\nend\n")
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "trusted server compiles; untrusted native server is refused", %{root: root} do
      log = capture_log(fn ->
        result = Nexus.Unit.compile_workbook(root)
        send(self(), {:result, result})
      end)

      assert_received {:result, %{compiled: compiled}}
      names = Enum.map(compiled, &to_string/1)
      assert Enum.any?(names, &(&1 =~ "Alpha")), "trusted server should compile"
      refute Enum.any?(names, &(&1 =~ "Evilsvc")), "untrusted native server must NOT compile"
      assert log =~ "refused native `server`"
      assert log =~ "tenants/evil.work"
    end
  end
end
