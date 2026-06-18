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

  # The registry is the UNION of two capability vocabularies the runtime speaks:
  #
  #  • sandbox caps (`sandbox?: true`) — net/kv/secrets/fs/exec — the per-unit grants
  #    an author writes; each projects a self-contained WIT `interface` so a generated
  #    component package validates standalone. Read by `Workbooks.Wit`.
  #  • runtime caps (`import:`) — vfs/commands/llm/browse/parallel — the live WIT-typed
  #    Instance Dock seam (`instance/imports.ex`), each projecting one host import name.
  #    Locked by the characterization snapshot; the seam will reproject from here.
  @registry %{
    "net" => %{interface: "host-net", wit: "interface host-net {\n  fetch: func(url: string) -> string;\n}", sandbox?: true},
    "kv" => %{interface: "host-kv", wit: "interface host-kv {\n  get: func(key: string) -> string;\n  put: func(key: string, val: string);\n}", sandbox?: true},
    "secrets" => %{interface: "host-secrets", wit: "interface host-secrets {\n  read: func(key: string) -> string;\n}", sandbox?: true},
    "fs" => %{interface: "host-fs", wit: "interface host-fs {\n  read: func(path: string) -> string;\n  write: func(path: string, data: string);\n}", sandbox?: true},
    "exec" => %{interface: "host-exec", wit: "interface host-exec {\n  run: func(cmd: string, args: list<string>) -> string;\n}", sandbox?: true},
    "vfs" => %{import: "vfs-query"},
    "commands" => %{import: "run-command"},
    "llm" => %{import: "llm-complete"},
    "browse" => %{import: "browse-fetch"},
    "parallel" => %{import: "run-command-many"}
  }

  # spec grant → the live runtime capability it maps onto (best-effort; the obvious
  # correspondences only). Used when the generated-WIT grant vocabulary meets the
  # runtime seam; secrets/fs have no runtime-cap analogue yet.
  @grant_aliases %{"net" => "browse", "kv" => "vfs", "exec" => "commands", "llm" => "llm", "browse" => "browse"}

  @doc "Every capability name in the registry (both vocabularies)."
  def capabilities, do: Map.keys(@registry)

  @doc "The per-unit sandbox-enforced capabilities (granted by an author, audited by the weave)."
  def sandbox_capabilities, do: for({c, %{sandbox?: true}} <- @registry, do: c)

  @doc "The live runtime seam capabilities (the WIT-typed Instance Dock imports)."
  def runtime_capabilities, do: for({c, m} <- @registry, Map.has_key?(m, :import), do: c)

  @doc "Is `cap` a known capability?"
  def capability?(cap), do: Map.has_key?(@registry, cap)

  @doc "Is `cap` a sandbox cap that projects a generated WIT interface?"
  def sandbox_capability?(cap), do: get_in(@registry, [cap, :sandbox?]) == true

  @doc "The WIT interface name a sandbox capability imports (e.g. \"net\" → \"host-net\")."
  def interface_name(cap), do: get_in(@registry, [cap, :interface])

  @doc "The self-contained WIT interface definition for a sandbox capability."
  def interface_wit(cap), do: get_in(@registry, [cap, :wit])

  @doc "The host import name a runtime capability projects (e.g. \"llm\" → \"llm-complete\")."
  def import_name(cap), do: get_in(@registry, [cap, :import])

  @doc "The runtime capability a spec grant maps onto, if any."
  def runtime_cap_for(grant), do: @grant_aliases[grant]

  @doc "The raw registry map."
  def registry, do: @registry
end
