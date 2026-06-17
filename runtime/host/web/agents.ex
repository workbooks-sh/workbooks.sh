defmodule Workbooks.Web.Agents do
  @moduledoc """
  Agent-facing helpers for `Workbooks.Web`: the desktop picker catalog and the
  composed system prompt resolution (profile def → safe default, plus the
  progressive-disclosure work-kit + component-catalog sections).
  """

  # Build the agent catalog the desktop picker reads. Project agents (if a
  # workdir is given) override user agents override the builtin. Every entry is
  # {slug, path, scope, title, model, toolkits} — AgentCatalogEntry shape.
  def agent_catalog(workdir) do
    builtin = [%{slug: "waldo", path: "waldo", scope: "builtin", title: "Waldo", model: nil, toolkits: []}]

    project =
      if is_binary(workdir) and workdir != "",
        do: catalog_dir(Path.join([workdir, ".workbooks", "agents"]), "project"),
        else: []

    user = catalog_dir(Path.join(System.get_env("WB_PROFILE_DIR") || "/opt/profile", "agents"), "user")

    # De-dupe by slug, keeping the higher-precedence scope (project > user > builtin).
    (project ++ user ++ builtin)
    |> Enum.reduce({[], MapSet.new()}, fn a, {acc, seen} ->
      if MapSet.member?(seen, a.slug), do: {acc, seen}, else: {[a | acc], MapSet.put(seen, a.slug)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp catalog_dir(dir, scope) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".html"))
        |> Enum.map(fn f ->
          def = Workbooks.AgentDef.parse(File.read!(Path.join(dir, f)))
          slug = def.id || Path.rootname(f)
          %{slug: slug, path: f, scope: scope, title: def.tagline || slug, model: def.model, toolkits: def.toolkits}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # Resolve an agent's system prompt by slug — the profile def if present, else a
  # safe default so voice/chat work without a provisioned profile. Slug is
  # path-validated (no traversal out of the agents dir).
  def agent_system_prompt(slug) do
    default =
      "You are Waldo, the user's resident assistant inside Workbooks. Be concise, warm, and helpful. " <>
        "Help them navigate and operate their workspace — answer questions, search, open things — by voice or text. " <>
        "You work problems WITH the user; you never run off on your own.\n\n" <>
        "REPLY STYLE: answer the user DIRECTLY in prose — just write your response. " <>
        "Only call a tool when you genuinely need to act (search, open a tab, run something); " <>
        "do NOT wrap a plain answer in a tool call. Your text streams to the user as you write it.\n\n" <>
        "RICH REPLIES (optional): when a structured or visual answer helps, write inline `<work-*>` " <>
        "HTML directly in your message — the chat renders the SDK's real custom elements as " <>
        "interactive cards. The available tags are listed in the Components section below, " <>
        "discovered from your component toolkit. Use NO `#+` directives — just the HTML. Emit a " <>
        "component when you took an action worth confirming or when offering the user a next step; " <>
        "use plain prose for ordinary replies (it streams).\n\n" <>
        "OPEN WHAT YOU BUILD: the moment you create or write a workbook or file, OPEN it for the user with `work app open-tab <path>` (you have the workbooks-browser toolkit) so it appears live in their workspace — never leave a workbook created-but-unopened. Create the file, open it, then confirm."

    # Resolve the base prompt + the agent's declared toolkits. Waldo (the
    # default) ALWAYS gets workbooks-browser (drive the app: work app …, work env
    # request …) AND workbooks-cli (deploy + publish: work deploy …, work publish …).
    # A provisioned <slug>.html overrides.
    {base, toolkits} =
      with true <- is_binary(slug) and Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/i, slug),
           dir <- System.get_env("WB_PROFILE_DIR") || "/opt/profile",
           path <- Path.join([dir, "agents", "#{slug}.html"]),
           {:ok, html} <- File.read(path),
           %{system: sys, toolkits: tks} when is_binary(sys) and sys != "" <- Workbooks.AgentDef.parse(html) do
        {sys, tks}
      else
        # Waldo also gets `workponents` (the component work-kit) so the
        # rich-reply path resolves a component catalog — the chat renders the
        # SDK `work-*` elements inline.
        _ -> {default, ["workbooks-browser", "workbooks-cli", "workponents"]}
      end

    # Tier-1 progressive disclosure: append the compact work-kit index (skill
    # names) so the agent knows what it can do; bodies stay on demand via `work
    # kit show`. When the closure includes a component work-kit, append
    # the catalog of `work-*` tags DISCOVERED from its CEM (not hardcoded).
    base
    |> append_section(Workbooks.WorkKits.injection_text(toolkits))
    |> append_section(Workbooks.WorkKits.component_catalog(toolkits))
  end

  defp append_section(text, ""), do: text
  defp append_section(text, section), do: text <> "\n\n" <> section
end
