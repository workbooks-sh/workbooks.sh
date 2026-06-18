defmodule WorkCLI.Platform do
  @moduledoc """
  The platform surface — identity + contexts + the cloud control plane. `ctx` manages targets
  (kubectl-style), `nexus` points the active context at an engine, `login`/`whoami` carry identity
  against the control plane. Local context ops are pure; `login` does a device flow (or takes a
  `--token`) and stores the credential under `~/.work`.
  """

  alias WorkCLI.Context
  alias WorkCore.Log


  @doc "work ctx list — show the targets, marking the active one."
  def ctx_list do
    ctx = Context.load()
    Log.prompt("work ctx")

    for {name, a} <- Enum.sort_by(ctx.targets, &elem(&1, 0)) do
      mark = if name == ctx.active, do: Log.paint("●", :ok), else: Log.dim("○")
      meta = [a["nexus"], a["org"], a["workspace"]] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
      Log.info("#{mark} " <> Log.cmd(name) <> "  " <> Log.dim(meta))
    end

    :ok
  end

  @doc "work ctx use <name> — switch the active target."
  def ctx_use(name) do
    Log.prompt("work ctx use #{name}")

    case Context.use(name) do
      :ok -> (Log.ok("active context: #{name}"); :ok)
      {:error, :unknown} -> (Log.error("no context named #{name}", detail: "`work ctx set #{name} --nexus <url>`"); {:error, :unknown})
    end
  end

  @doc "work ctx set <name> [--nexus url] [--org o] [--workspace w] — upsert + activate a target."
  def ctx_set(name, opts) do
    Log.prompt("work ctx set #{name}")
    Context.set(name, %{"nexus" => opts[:nexus], "org" => opts[:org], "workspace" => opts[:workspace]})
    a = Context.active_target()
    Log.ok("context #{name} active", detail: a["nexus"])
    :ok
  end

  @doc "work nexus <url> — point the active context's nexus at <url>."
  def nexus(url) do
    Log.prompt("work nexus #{url}")
    ctx = Context.load()
    Context.set(ctx.active, %{"nexus" => url})
    Log.ok("#{ctx.active} → #{url}")
    :ok
  end

  @doc "work whoami — the active context + identity."
  def whoami do
    ctx = Context.load()
    a = ctx.targets[ctx.active] || %{}
    Log.prompt("work whoami")
    Log.ok(ctx.active, detail: a["nexus"])
    if a["org"], do: Log.step("org " <> Log.path(a["org"]) <> (if a["workspace"], do: " · workspace " <> Log.path(a["workspace"]), else: ""))

    case identity() do
      nil -> Log.step(Log.dim("not logged in — `work login` for the cloud control plane"))
      who -> Log.step("identity " <> Log.path(who))
    end

    :ok
  end

  @doc "work login [url] [--token t] — authenticate to the control plane; stores the credential."
  def login(url, opts) do
    url = url || "https://api.workbooks.sh"
    Log.prompt("work login #{url}")

    case opts[:token] do
      t when is_binary(t) and t != "" ->
        store_credential(url, t)
        Log.ok("logged in", detail: url)
        :ok

      _ ->
        # Device flow: the real exchange happens against the control plane; here we point the user at
        # it and accept the token via --token (or WB_TOKEN) so the flow is scriptable + testable.
        case System.get_env("WB_TOKEN") do
          t when is_binary(t) and t != "" -> (store_credential(url, t); Log.ok("logged in (WB_TOKEN)", detail: url); :ok)
          _ ->
            Log.step("visit " <> Log.path(url <> "/device") <> " to authorize, then re-run with --token <t>")
            Log.step(Log.dim("(device-code exchange lands with the control-plane client)"))
            {:error, :pending}
        end
    end
  end

  # ── credential storage (~/.work/credentials, 0600) ─────────────────────────────────────────
  defp store_credential(url, token) do
    File.mkdir_p!(Path.dirname(creds_path()))
    File.write!(creds_path(), "#{url}\t#{token}\n")
    File.chmod(creds_path(), 0o600)
  end

  defp identity do
    case File.read(creds_path()) do
      {:ok, data} ->
        case String.split(String.trim(data), "\t") do
          [url, _token] -> url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp creds_path, do: Application.get_env(:work_cli, :creds_file) || Path.expand("~/.work/credentials")
end
