defmodule Nexus.Trust do
  @moduledoc """
  The authorship trust gate (wb-rh95). `client`/`sandbox` units run as WASM — bounded + capability-
  scoped (the `Nexus.Sandbox` hardening). `server`/`worker`/`def`/`hook`/`test`/`auth` units compile to
  **native BEAM Elixir** and run with full host privilege: there is no in-process way to contain native
  code, so the trust boundary is the **machine** (one nexus per trust-domain — see `Nexus.Sandbox`).

  This module enforces that boundary at AUTHORSHIP: a workspace declared **untrusted**
  (`Nexus.Config.untrusted_workspaces`, a deploy attr) may author only WASM kinds. A native-BEAM unit
  from an untrusted subtree is rejected at weave/load — it never compiles, so an untrusted tenant can't
  land arbitrary Elixir on the host. Trusted workspaces (the neutral default) are unchanged.
  """

  # Kinds whose authored body becomes / drives native Elixir on the host BEAM.
  @native_kinds ~w(server worker def hook test auth)

  @doc "Is `kind` a native-BEAM kind (runs authored Elixir on the host, not in a WASM sandbox)?"
  def native_kind?(kind) when is_binary(kind), do: kind in @native_kinds
  def native_kind?(_), do: false

  @doc "The native-BEAM kind vocabulary."
  def native_kinds, do: @native_kinds

  @doc """
  Is `rel_path` (a workbook-relative `.work` path) inside an untrusted subtree? A subtree prefix
  matches a path that equals it or is nested under it. Empty list (default) ⇒ everything trusted.
  """
  def untrusted_path?(rel_path, untrusted \\ nil) do
    untrusted = untrusted || Nexus.Config.untrusted_workspaces()
    norm = rel_path |> to_string() |> String.trim_leading("./")
    Enum.any?(untrusted, fn pfx ->
      pfx = String.trim_trailing(pfx, "/")
      norm == pfx or String.starts_with?(norm, pfx <> "/")
    end)
  end

  @doc """
  Gate one `kind` authored at `rel_path`: `:ok` if allowed, `{:error, {:untrusted_native_kind, kind,
  rel_path}}` if a native kind is authored in an untrusted subtree.
  """
  def gate(kind, rel_path, untrusted \\ nil) do
    if native_kind?(kind) and untrusted_path?(rel_path, untrusted),
      do: {:error, {:untrusted_native_kind, kind, to_string(rel_path)}},
      else: :ok
  end

  @doc """
  Partition `{node, rel_path}` pairs into `{allowed, rejected}` — rejected = native units from
  untrusted subtrees. `rejected` entries are `{node, rel_path, reason}` for logging at the call site.
  """
  def partition(node_paths) do
    untrusted = Nexus.Config.untrusted_workspaces()

    Enum.reduce(node_paths, {[], []}, fn {node, path}, {ok, bad} ->
      kind = Map.get(node, :kind)

      case gate(kind, path, untrusted) do
        :ok -> {[node | ok], bad}
        {:error, reason} -> {ok, [{node, path, reason} | bad]}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
  end
end
