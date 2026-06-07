defmodule Workbooks.Workspace do
  @moduledoc """
  The `workspace.org` manifest (Phase 3 composition) — declares a workspace's
  MEMBERS (workbooks/containers) by DID or path, plus the access scope each
  grants. The structure lives in config, decoupled from the file tree: a member
  is referenced (resolved on demand) or embedded, and reorganizing = editing the
  manifest, not moving files (see docs/IDENTITY-GIT-MONOREPO.org).

  A member is any heading tagged `:member:` (or carrying a `:DID:`/`:PATH:` prop):

      #+TITLE: Acme campaign
      #+WORKSPACE: acme-campaign
      * Brand book                        :member:
        :PROPERTIES:
        :DID: did:key:z6Mk…
        :SCOPE: read
        :END:
      * Launch deck                       :member:
        :PROPERTIES:
        :PATH: decks/launch.html
        :SCOPE: write
        :END:

  Parsing reuses `Workbooks.OQL.parse_headlines/1` (one org parser, no second
  hand-roll). Pure data — the Library layer composes these into an access graph.
  """
  alias Workbooks.OQL

  @doc "Parse a workspace.org → %{title, slug, members: [%{id, ref, scope}]}."
  def parse(org) when is_binary(org) do
    members =
      org
      |> OQL.parse_headlines()
      |> Enum.filter(&member?/1)
      |> Enum.map(&to_member/1)

    %{title: directive(org, "TITLE") || "Untitled workspace",
      slug: directive(org, "WORKSPACE") || slug(directive(org, "TITLE") || "workspace"),
      members: members}
  end

  defp member?(h), do: "member" in (h["tags"] || []) or Map.has_key?(h["props"] || %{}, "DID") or Map.has_key?(h["props"] || %{}, "PATH")

  defp to_member(h) do
    props = h["props"] || %{}
    ref = cond do
      props["DID"] -> {:did, props["DID"]}
      props["PATH"] -> {:path, props["PATH"]}
      true -> {:unresolved, nil}
    end

    %{id: slug(h["title"]), title: h["title"], ref: ref, scope: String.downcase(props["SCOPE"] || "read")}
  end

  defp directive(org, key) do
    case Regex.run(~r/^#\+#{key}:\s*(.+)$/mi, org) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp slug(title) do
    title |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") |> String.slice(0, 48)
  end
end
