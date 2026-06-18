defmodule Workbooks.Dock do
  @moduledoc """
  §3 — the single capability **registry**: one source of truth for what host
  capabilities exist, the WIT interface each projects, and the grant that unlocks it.

  This is step 1 of collapsing the four parallel Dock seams (Instance WIT imports,
  host_broker JSON envelope, RustDock/JsDock core ABI) into one. Those seams become
  *transports* that project from this registry (later steps). Today it is already the
  source `Workbooks.Wit` reads to generate a unit's `import`s — so §2's generated
  worlds and the Dock are the same surface, by construction rather than by coincidence.
  """

  # capability → its host-interface projection + the grant that unlocks it.
  # `sandbox?` marks the sandbox-enforced caps (net/kv/secrets/fs/exec) that a unit
  # grants per-unit; the others are nexus-tier services folded in for the union.
  @registry %{
    "net" => %{
      interface: "host-net",
      wit: "interface host-net {\n  fetch: func(url: string) -> string;\n}",
      sandbox?: true
    },
    "kv" => %{
      interface: "host-kv",
      wit: "interface host-kv {\n  get: func(key: string) -> string;\n  put: func(key: string, val: string);\n}",
      sandbox?: true
    },
    "secrets" => %{
      interface: "host-secrets",
      wit: "interface host-secrets {\n  read: func(key: string) -> string;\n}",
      sandbox?: true
    },
    "fs" => %{
      interface: "host-fs",
      wit: "interface host-fs {\n  read: func(path: string) -> string;\n  write: func(path: string, data: string);\n}",
      sandbox?: true
    },
    "exec" => %{
      interface: "host-exec",
      wit: "interface host-exec {\n  run: func(cmd: string, args: list<string>) -> string;\n}",
      sandbox?: true
    }
  }

  @doc "Every capability name in the registry."
  def capabilities, do: Map.keys(@registry)

  @doc "The sandbox-enforced capabilities (granted per-unit, audited by the weave gate)."
  def sandbox_capabilities, do: for({c, %{sandbox?: true}} <- @registry, do: c)

  @doc "Is `cap` a known capability?"
  def capability?(cap), do: Map.has_key?(@registry, cap)

  @doc "The WIT interface name a capability imports (e.g. \"net\" → \"host-net\")."
  def interface_name(cap), do: get_in(@registry, [cap, :interface])

  @doc "The self-contained WIT interface definition for a capability."
  def interface_wit(cap), do: get_in(@registry, [cap, :wit])

  @doc "The raw registry map."
  def registry, do: @registry
end
