defmodule Workbooks.PolicyNetworkTest do
  @moduledoc """
  SECURITY REGRESSION (wb-sec, finding #7): host network egress (wasi:http +
  inherit_network + DNS) must be GATED by the Policy capability set, not granted
  to every Instance unconditionally.

  Root cause: `Instance.init/1` hardcoded `allow_http: true`. In stock wasmex that
  single `WasiP2Options.allow_http` flag gates BOTH
  `wasmtime_wasi_http::add_only_http_to_linker_sync` (the wasi:http import) AND,
  in store.rs, `wasi_ctx_builder.inherit_network()` + `allow_ip_name_lookup(true)`
  (the real host socket pool + DNS). So with it hardcoded true, even the most
  restrictive `:minimal` profile (caps: vfs, commands) got full outbound network.

  Fix: `allow_http` is now derived from the profile via `Policy.allow_http?/1` —
  true only when the caps include `net` or `browse`. A non-network profile gets
  NO http import linked and NO inherited network/DNS, so a component cannot open
  outbound connections regardless of what wasi:* types the linker exposes.

  NOTE on coverage: a full wasi:http *exfiltration* fixture (cargo-component +
  waki) is out of scope for this suite (it needs a bespoke WIT world importing
  wasi:http + the http adapter, and a network-fetched toolchain). The gate is the
  enforcement point, asserted here directly; an instantiation smoke test confirms
  the non-network path is unbroken under the tighter setting.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Policy, Instance}

  describe "Policy.allow_http?/1 gate" do
    test "minimal profile gets NO network" do
      refute Policy.allow_http?(:minimal)
    end

    test "network and posix profiles get network" do
      assert Policy.allow_http?(:network)
      assert Policy.allow_http?(:posix)
    end

    test "an unknown profile defaults to the minimal (no-network) gate" do
      refute Policy.allow_http?(:does_not_exist)
    end

    test "the gate is consistent with the declared caps" do
      for p <- Policy.profiles() do
        caps = Policy.caps(p)
        expected = "net" in caps or "browse" in caps
        assert Policy.allow_http?(p) == expected
      end
    end
  end

  describe "instantiation under the tightened (no-network) minimal profile" do
    @fixture "build/fixtures/engine-probe.wasm"

    test "a non-network component still instantiates and runs under :minimal" do
      bytes = File.read!(@fixture)
      id = "polnet-#{System.unique_integer([:positive])}"
      {:ok, _} = Instance.Supervisor.start_instance(id, bytes, policy: :minimal)
      on_exit(fn -> Instance.Supervisor.stop_instance(id) end)

      # Proves allow_http:false (no inherit_network) does not break a component
      # that uses only the Dock + ambient wasi — i.e. the fix is not over-broad.
      assert {:ok, ran} = Instance.call(id, "run", ["command"])
      out = Jason.decode!(ran)
      assert out["info"]["profile"] == "minimal"
    end
  end

  test "wb-8w8x: an UNKNOWN/typo'd profile FAILS CLOSED to compute (vfs-only), not over-granting minimal" do
    # a bogus profile must get LEAST privilege — no exec/kv/secrets/sockets/net
    caps = Workbooks.Policy.caps(:totally_bogus_profile)
    assert caps == ~w(vfs)
    refute "exec" in caps
    refute "secrets" in caps
    refute "tcp" in caps
    refute Workbooks.Policy.allow_http?(:totally_bogus_profile)
    assert Workbooks.Policy.timeout(:totally_bogus_profile) == Workbooks.Policy.timeout(:compute)
  end
end
