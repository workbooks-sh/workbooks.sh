defmodule Workbooks.Demos.Seed do
  @moduledoc """
  The demo-environment seed (recording-system findings §3) — a reproducible,
  no-corners-cut Workbooks demo workspace materialized FROM A GIT-BACKED ORG
  FIXTURE TREE, not a database.

  The fixture tree lives at `runtime/demos/seed/` and is the only source of
  truth: workspaces (`workspace.org`), team members (tenants with deterministic
  signing seeds → stable DIDs), real built workbooks, custom toolkits (signed),
  a custom Dock preset, and replayed agent transcripts. Editing the demo env =
  editing those files + `seed.exs`, NEVER host code.

  `materialize/1` (peer to `Workbooks.Demos.Build`) reads `seed.exs`, then for
  each member:

    * wipes + recreates the tenant repo under `$WB_DATA/<tenant>`,
    * installs a DETERMINISTIC Ed25519 keypair from the member's fixed seed so
      its `did:key` is stable across every re-materialization,
    * copies the tenant's fixture files in (workspace.org, workbooks, agents),
    * copies the custom toolkits into `$WB_WORKKITS_ROOT` (and the author's repo),
    * SIGNS the third-party toolkits as their owning tenant,
    * BUILDS the build-targeted workbooks at seed time (real run records — no
      faked outputs),
    * git-commits the repo as the member's identity,
    * writes the Dock preset + the determinism env (frozen clock, replay).

  Determinism levers (the no-flaky requirement): frozen clock (`WB_DEMO_NOW`),
  replay transcripts (`WB_DEMO_REPLAY`), and the fixed per-tenant key seeds.

  Drive it from the CLI: `work demo seed [--fresh] [--dry-run] [--no-build]`.
  """

  @seed_dir Path.expand("../../demos/seed", __DIR__)

  @doc "Absolute path to the fixture tree (runtime/demos/seed)."
  def seed_dir, do: @seed_dir

  @doc "The parsed seed manifest (seed.exs). Pure data."
  def manifest do
    {m, _} = Code.eval_file(Path.join(@seed_dir, "seed.exs"))
    m
  end

  @doc """
  Materialize the demo environment. Options:

    * `:dry_run` (bool) — describe the actions, touch nothing on disk.
    * `:fresh`   (bool, default true) — wipe each tenant repo first.
    * `:build`   (bool, default true) — actually tangle+build the build-targeted
      workbooks (set false to skip the slow compile lanes in a smoke run).

  Returns `%{members: [...], toolkits: [...], dock: ..., env: %{...}, dry_run: bool}`.
  """
  def materialize(opts \\ []) do
    dry = Keyword.get(opts, :dry_run, false)
    fresh = Keyword.get(opts, :fresh, true)
    build? = Keyword.get(opts, :build, true)
    m = manifest()

    data_root = System.get_env("WB_DATA", "tmp/data")
    tk_root = toolkits_root()

    member_results =
      for member <- m.members do
        materialize_member(member, m, data_root, tk_root, fresh, build?, dry)
      end

    tk_results = if dry, do: Enum.map(m.toolkits, &%{toolkit: &1, action: :"would-install+sign"}),
                         else: install_and_sign_toolkits(m, tk_root)

    dock = write_dock(m, dry)

    env = %{
      "WB_TENANCY_MODE" => "multi",
      "WB_DEMO" => "1",
      "WB_DEMO_REPLAY" => "1",
      "WB_DEMO_NOW" => m.frozen_at,
      "WB_WORKKITS_ROOT" => tk_root,
      "WB_DATA" => data_root
    }

    %{
      dry_run: dry,
      data_root: data_root,
      toolkits_root: tk_root,
      members: member_results,
      toolkits: tk_results,
      dock: dock,
      replay: m.replay,
      env: env
    }
  end

  # --- per-member materialization -------------------------------------------

  defp materialize_member(member, m, data_root, _tk_root, fresh, build?, dry) do
    tenant = member.tenant
    repo = Path.join(data_root, tenant)
    src = Path.join(@seed_dir, "tenants/#{tenant}")

    actions = []

    actions = if fresh, do: actions ++ ["wipe #{repo}"], else: actions
    actions = actions ++ ["install deterministic keypair (#{String.slice(member.seed_b64, 0, 12)}…)"]
    actions = actions ++ ["copy fixtures from #{Path.relative_to_cwd(src)}"]

    # The author tenant also gets the custom toolkit dirs in its repo so its
    # workspace.org members (toolkits/<id>/manifest.org) resolve.
    author? = tenant == m.toolkits_owner
    actions = if author?, do: actions ++ ["copy #{length(m.toolkits)} toolkit dir(s) into repo"], else: actions

    build_targets = Map.get(member, :build, [])
    actions = if build? and build_targets != [], do: actions ++ Enum.map(build_targets, &"build #{&1}"), else: actions
    actions = actions ++ ["git commit as #{member.display}"]

    unless dry do
      if fresh, do: File.rm_rf!(repo)
      File.mkdir_p!(repo)

      # Deterministic keypair FIRST (before ensure_repo runs, so it doesn't mint
      # a random one). Same on-disk format as Workbooks.Git.ensure_keypair.
      install_keypair(repo, tenant, member.seed_b64)

      copy_tree(src, repo)

      if author? do
        for tk <- m.toolkits do
          copy_tree(Path.join(@seed_dir, "toolkits/#{tk}"), Path.join([repo, "toolkits", tk]))
        end
      end

      # ensure_repo inits git + gitignore (and leaves our keypair in place).
      Workbooks.Git.ensure_repo(tenant)

      built =
        if build? do
          for t <- build_targets, do: {t, build_workbook(repo, t)}
        else
          []
        end

      id = Workbooks.Git.identity(tenant, member.display)
      commit_all(repo, id, "seed: #{member.workspace} (#{member.display})")

      did = safe_did(tenant)

      %{
        tenant: tenant, display: member.display, role: member.role,
        workspace: member.workspace, repo: repo, did: did,
        built: Enum.map(built, fn {t, r} -> %{workbook: t, result: r} end),
        actions: actions
      }
    else
      %{
        tenant: tenant, display: member.display, role: member.role,
        workspace: member.workspace, repo: repo,
        did: deterministic_did(member.seed_b64),
        actions: actions
      }
    end
  end

  # Build a workbook at seed time → a REAL run record (findings: don't fake).
  defp build_workbook(repo, rel) do
    path = Path.join(repo, rel)

    cond do
      not File.exists?(path) ->
        {:error, :missing}

      String.ends_with?(rel, ".org") ->
        org = File.read!(path)

        results =
          Workbooks.PackageManager.tangle(org)
          |> Enum.map(fn
            {name, lang, {:ok, wasm, how}} ->
              out = Workbooks.PackageManager.run(wasm, "demo") |> String.trim()
              %{name: name, lang: lang, built: how, output: out}

            {name, lang, other} ->
              %{name: name, lang: lang, error: inspect(other)}
          end)

        # Persist the run record next to the workbook so the Browser shows it.
        rec = %{workbook: rel, ran_at: manifest().frozen_at, components: results}
        runs = Path.join(repo, "runs")
        File.mkdir_p!(runs)
        File.write!(Path.join(runs, Path.basename(rel, ".org") <> ".json"), Jason.encode!(rec, pretty: true))
        {:ok, results}

      true ->
        {:skip, :not_buildable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # --- toolkits --------------------------------------------------------------

  defp install_and_sign_toolkits(m, tk_root) do
    File.mkdir_p!(tk_root)

    for tk <- m.toolkits do
      dest = Path.join(tk_root, tk)
      File.rm_rf!(dest)
      copy_tree(Path.join(@seed_dir, "toolkits/#{tk}"), dest)
      # Sign as the owning tenant so `work kit verify` is green on a
      # #+TRUST: third-party manifest.
      signed = Workbooks.WorkKits.sign_text(tk, m.toolkits_owner, tk_root)
      %{toolkit: tk, root: dest, signed: signed}
    end
  end

  # --- dock ------------------------------------------------------------------

  defp write_dock(m, dry) do
    src = Path.join(@seed_dir, m.dock)
    dest = Path.join(System.get_env("WB_DATA", "tmp/data"), "demo-dock.json")

    if dry do
      %{action: :"would-write", from: m.dock, to: dest}
    else
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(src, dest)
      %{from: m.dock, to: dest}
    end
  end

  # --- keypair (deterministic, matches Workbooks.Git on-disk format) ---------

  defp install_keypair(repo, tenant, seed_b64) do
    seed = Base.decode64!(seed_b64)
    {pub, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    # Store the SEED as the private half (ed25519 priv == the 32-byte seed) —
    # exactly what Git.ensure_keypair persists when restoring from WB_SIGNING_KEY.
    path = Path.join([repo, ".workbooks", "#{tenant}.ed25519"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Base.encode16(seed, case: :lower))
    File.write!(path <> ".pub", Base.encode16(pub, case: :lower))
    :ok
  end

  # did:key for a member from its fixed seed, WITHOUT touching disk (dry-run).
  defp deterministic_did(seed_b64) do
    {pub, _} = :crypto.generate_key(:eddsa, :ed25519, Base.decode64!(seed_b64))
    "did:key:z" <> base58btc(<<0xED, 0x01>> <> pub)
  end

  defp safe_did(tenant) do
    Workbooks.Git.did(tenant)
  rescue
    _ -> "(did unavailable)"
  end

  # --- helpers ---------------------------------------------------------------

  defp copy_tree(src, dest) do
    File.mkdir_p!(dest)
    File.cp_r!(src, dest)
  end

  defp commit_all(repo, id, msg) do
    git(repo, ["add", "-A"])
    git(repo, ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", msg], commit_env(id))
  end

  defp commit_env(%{author: author, email: email}) do
    [
      {"GIT_AUTHOR_NAME", author}, {"GIT_AUTHOR_EMAIL", email},
      {"GIT_COMMITTER_NAME", author}, {"GIT_COMMITTER_EMAIL", email}
    ]
  end

  defp git(dir, args, env \\ []) do
    System.cmd("git", ["-c", "safe.directory=*"] ++ args, cd: dir, stderr_to_stdout: true, env: env)
  end

  defp toolkits_root do
    System.get_env("WB_WORKKITS_ROOT") ||
      Path.join(System.get_env("WB_DATA", "tmp/data"), "toolkits")
  end

  # base58btc (multibase z) — same scheme as Workbooks.Git.did/1, kept local so
  # dry-run never has to hit the keystore.
  @b58 ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  defp base58btc(bin),
    do: String.duplicate("1", leading_zeros(bin, 0)) <> enc58(:binary.decode_unsigned(bin), [])

  defp enc58(0, acc), do: List.to_string(acc)
  defp enc58(n, acc), do: enc58(div(n, 58), [Enum.at(@b58, rem(n, 58)) | acc])
  defp leading_zeros(<<0, rest::binary>>, n), do: leading_zeros(rest, n + 1)
  defp leading_zeros(_, n), do: n
end
