defmodule WorkCore.Capabilities do
  @moduledoc """
  The single capability **catalog** — one source of truth for what host capabilities exist, the WIT
  interface each projects, and the grant that unlocks it. Pure data + pure queries (no NIF, no
  runtime), so the `.work` toolchain (`WorkCore.Wit`) and the runtime Dock seam read the SAME
  vocabulary. The runtime membrane (`Nexus.Dock`) keeps the live host implementations and delegates
  these catalog queries here.

  The registry is the UNION of two capability vocabularies:
    * sandbox caps (`sandbox?: true`) — net/kv/secrets/fs/exec — per-unit grants an author writes;
      each projects a self-contained WIT `interface`.
    * runtime caps (`import:`) — vfs/commands/llm/browse/parallel — the live WIT-typed Instance seam.
  """

  @registry %{
    "net" => %{interface: "host-net", wit: "interface host-net {\n  fetch: func(url: string) -> string;\n}", sandbox?: true, dock_fns: ~w(fetch get post)},
    "kv" => %{interface: "host-kv", wit: "interface host-kv {\n  get: func(key: string) -> string;\n  put: func(key: string, val: string);\n}", sandbox?: true, dock_fns: ~w(kv put read)},
    "secrets" => %{interface: "host-secrets", wit: "interface host-secrets {\n  read: func(key: string) -> string;\n}", sandbox?: true, dock_fns: ~w(secret secrets)},
    "fs" => %{interface: "host-fs", wit: "interface host-fs {\n  read: func(path: string) -> string;\n  write: func(path: string, data: string);\n}", sandbox?: true, dock_fns: ~w(fs file)},
    "exec" => %{interface: "host-exec", wit: "interface host-exec {\n  run: func(cmd: string, args: list<string>) -> string;\n}", sandbox?: true, dock_fns: ~w(exec run)},
    "vfs" => %{import: "vfs-query", sig: "func(sql: string) -> string"},
    "commands" => %{import: "run-command", sig: "func(command: string, input: string, args: list<string>) -> string"},
    "llm" => %{import: "llm-complete", sig: "func(prompt: string) -> string"},
    "browse" => %{import: "browse-fetch", sig: "func(url: string) -> string"},
    "parallel" => %{import: "run-command-many", sig: "func(command: string, inputs: string) -> string"}
  }

  # the always-present imports / the entrypoint export that bookend the engine world
  @engine_always "import session-info: func() -> string;"
  @engine_export "export run: func(input: string) -> string;"

  # The RustDock core-module ABI transport: each capability projects one or more `env.host_*` imports.
  @rust_ambient ~w(host_now host_log)
  @rust_abi %{
    "egress" => ~w(host_http_get host_http_get_many),
    "exec" => ~w(host_exec host_parallel_map),
    "encode" => ~w(host_ffmpeg_encode),
    "udp" => ~w(host_udp),
    "tls" => ~w(host_tls),
    "tcp" => ~w(host_tcp),
    "queue" => ~w(host_publish host_poll),
    "secrets" => ~w(host_sign),
    "kv" => ~w(host_kv_put host_kv_get),
    "vfs" => ~w(host_vfs_write host_vfs_read)
  }

  # spec grant → the live runtime capability it maps onto (best-effort; obvious correspondences only).
  @grant_aliases %{"net" => "browse", "kv" => "vfs", "exec" => "commands", "llm" => "llm", "browse" => "browse"}

  # The host functions a unit may call by name (the impls live in the runtime membrane `Nexus.Dock`;
  # the canonical NAME list lives here so the capability audit — `WorkCore.Audit` — is pure/local).
  @host_fns ~w(now emit store load fetch complete)

  @doc "The canonical host-function names a unit can import (audited against a unit's `grant`s)."
  def host_fn_names, do: @host_fns

  @doc "Every capability name in the registry (both vocabularies)."
  def capabilities, do: Map.keys(@registry)

  @doc "The per-unit sandbox-enforced capabilities (granted by an author, audited by the weave)."
  def sandbox_capabilities, do: for({c, %{sandbox?: true}} <- @registry, do: c)

  @doc "The live runtime seam capabilities (the WIT-typed Instance Dock imports)."
  def runtime_capabilities, do: for({c, m} <- @registry, Map.has_key?(m, :import), do: c)

  # reverse index: a `Dock.<fn>` a unit calls → the sandbox capability it exercises
  @dock_fn_index (for {cap, %{dock_fns: fns}} <- @registry, f <- fns, into: %{}, do: {f, cap})

  @doc "The sandbox capability a `Dock.<fn>` call exercises (for the weave caps audit), or nil."
  def cap_for_dock_fn(fn_name), do: @dock_fn_index[to_string(fn_name)]

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

  @doc """
  The WIT import a granted capability projects — the one vocabulary both the generated world
  (`WorkCore.Wit`) and the runtime seam speak. `nil` if the grant has no projection.
  """
  def grant_import(grant) do
    cond do
      sandbox_capability?(grant) -> interface_name(grant)
      import_name(grant) -> import_name(grant)
      rc = runtime_cap_for(grant) -> import_name(rc)
      true -> nil
    end
  end

  @doc "The always-present RustDock ambient core-ABI imports."
  def rust_ambient, do: @rust_ambient

  @doc "The RustDock `env.host_*` core-ABI imports a capability projects."
  def rust_abi(cap), do: Map.get(@rust_abi, cap, [])

  @doc "Every RustDock core-ABI import name the registry knows (ambient + all caps)."
  def rust_abi_names do
    (@rust_ambient ++ (@rust_abi |> Map.values() |> List.flatten())) |> Enum.uniq() |> Enum.sort()
  end

  @doc "The raw registry map."
  def registry, do: @registry

  @doc """
  Generate the `workbooks:engine` Dock world from the registry — the typed surface a Workbook Instance
  runs against (session-info + every runtime capability's import + the `run` entrypoint). The world
  falls out of the registry, so it can't drift from the seam that projects it.
  """
  def engine_world do
    imports = for {_cap, %{import: name, sig: sig}} <- @registry, do: "import #{name}: #{sig};", into: []
    body = [@engine_always | Enum.sort(imports)] ++ [@engine_export]
    "package workbooks:engine;\n\nworld engine {\n" <> Enum.map_join(body, "\n", &("  " <> &1)) <> "\n}\n"
  end
end
