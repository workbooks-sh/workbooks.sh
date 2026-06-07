defmodule Workbooks.Toolkits do
  @moduledoc """
  Toolkit discovery (L4, wb-11ck.46) — the agent extensibility surface. A toolkit
  makes an agent competent with a CLI it has never seen: a `:toolkit:`-tagged Org
  node (the manifest front-door) names the CLI it wraps and indexes deep skill
  recipes the agent reads on demand. This module is the *discovery* half — the
  canonical concept, recreated on the kernel's existing tag/property extraction,
  not a port of the mainline layout.

  Discovery is one query — `(tags :toolkit:)` over the Context Tree. An `:agent:`
  node's `:TOOLKITS:` property lists the toolkits it may use; each name resolves
  to a `:toolkit:` node. No tool-search subsystem: org + the kernel. The skill
  bodies are read lazily (the agent `cat`s the skill file when a task routes to
  it); the runtime only resolves *which* toolkit, never inlines the manual.

  In the clean-room a toolkit's CLI is a WASM command (`run-command`,
  wb-11ck.21), not a native PATH binary — but the discovery contract is identical.
  """
  alias Workbooks.OQL

  @doc "Every `:toolkit:` node in a Context Tree — the `(tags :toolkit:)` query."
  def discover(org) when is_binary(org) do
    org |> OQL.parse_headlines() |> Enum.filter(&toolkit?/1) |> Enum.map(&view/1)
  end

  @doc """
  Discover toolkits on disk: read every `<root>/<name>/manifest.org`, run the same
  `(tags :toolkit:)` query over each, and tag the view with its directory so the
  agent can `cat` a skill on demand. This is the canonical filesystem-native
  shape — a toolkit is a directory; discovery is org + the kernel, no new infra.
  """
  def discover_dir(root) do
    Path.wildcard(Path.join(root, "*/manifest.org"))
    |> Enum.flat_map(fn manifest ->
      dir = Path.dirname(manifest)
      manifest |> File.read!() |> discover() |> Enum.map(&Map.put(&1, :dir, dir))
    end)
  end

  @doc "Skill names available in a toolkit dir (read the body on demand — progressive disclosure)."
  def skills(toolkit_dir) do
    Path.wildcard(Path.join([toolkit_dir, "skills", "*.org"]))
    |> Enum.map(&Path.basename(&1, ".org"))
    |> Enum.sort()
  end

  @doc """
  Resolve an `:agent:` node's `:TOOLKITS:` list → the toolkit nodes it may use,
  in declared order. Unknown names are dropped (a missing toolkit is not a crash).
  """
  def resolve(org, agent_id) when is_binary(org) do
    hs = OQL.parse_headlines(org)
    wanted = hs |> agent(agent_id) |> names()
    by_id = hs |> Enum.filter(&toolkit?/1) |> Map.new(&{&1["id"], view(&1)})
    wanted |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)
  end

  @doc """
  Resolve a toolkit by id and run its wrapped CLI as a registered WASM command —
  the vertical from L4 discovery to the L0 command leaf. The toolkit's `CLI_BIN`
  is the command name (jq, ripgrep, ...); in the clean-room that CLI is a
  sandboxed WASM command, not a native PATH binary.
  """
  def run(org, toolkit_id, input) when is_binary(org) do
    case org |> discover() |> Enum.find(&(&1.id == toolkit_id)) do
      nil -> {:error, {:no_toolkit, toolkit_id}}
      %{cli: nil} -> {:error, {:no_cli, toolkit_id}}
      %{cli: cli} -> Workbooks.CommandRegistry.run(cli, input)
    end
  end

  defp agent(hs, id), do: Enum.find(hs, &("agent" in &1["tags"] and &1["id"] == id))

  defp names(nil), do: []
  defp names(agent), do: (agent["props"]["TOOLKITS"] || "") |> String.split()

  defp toolkit?(h), do: "toolkit" in h["tags"]

  defp view(h) do
    %{
      id: h["id"],
      title: h["title"],
      cli: h["props"]["CLI_BIN"],
      status: h["props"]["STATUS"],
      skill_dir: h["props"]["SKILL_DIR"]
    }
  end
end
