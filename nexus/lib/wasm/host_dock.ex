defmodule TinyLasers.Wasm.HostDock do
  @moduledoc """
  The nexus **"dock" host concern** for TinyLasers.Wasm's typed host-call ABI
  (`tiny-lasers/docs/host-bridge-abi.md` §4) — the BEAM-native replacement for the wasm component-model
  import table (`Nexus.Sandbox` / wasmex, wb-vhq1u / wb-4z3fv).

  A retargeted guest (rust/c/zig/swift → **core** `wasm32-wasi`, route (a) — no componentize) calls the
  ONE host import `host_call("dock_<op>", [args…])`. The TL runtime does all §2 marshaling (reads the name
  + JSON args from guest memory, decodes the args array, JSON-encodes our result back into the guest's out
  buffer) and routes `dock_*` here by the `Host<Concern>` naming convention — **zero runtime changes to add
  a concern**. We only map `<op>` → `Nexus.Dock.impls/2` and apply the decoded args.

  Confinement is preserved exactly as wasmex gave it, now in BEAM code we own: `Dock.impls/2` is already
  tenant-bound + grant-filtered, so an ungranted or unknown op is simply absent from the map → we raise →
  the run traps (the guest can never reach a capability it did not grant). `tenant` + granted `caps` ride
  the run context (`:dock_tenant` / `:dock_caps`), planted by the call-site flip like `:tl_imports` — never
  guest-supplied, so no guest can address another tenant's data.
  """

  @doc """
  Route one typed host call: `host_call("dock_<op>", args)` → `Nexus.Dock.impls(tenant, caps)[op]`. `args`
  is the runtime-decoded JSON array (per §2); the return is a JSON-encodable term the runtime encodes back.
  """
  def call("dock_" <> op, args) when is_list(args) do
    tenant = Process.get(:dock_tenant) || Nexus.Store.default_tenant()
    caps = Process.get(:dock_caps) || :all

    case Map.get(Nexus.Dock.impls(tenant, caps), op) do
      {:fn, impl} -> apply(impl, args)
      # ungranted/unknown → absent from the grant-filtered map → trap (confinement invariant)
      _ -> raise ArgumentError, "dock: ungranted or unknown op #{inspect(op)}"
    end
  end
end
