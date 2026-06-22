defmodule Nexus.Workspaces do
  @moduledoc """
  The workspace TREE — the set of top-level workspaces under `WB_DATA`, each its OWN git remote / jj
  repo. A **general** agent (the workspace-scope tier; see the general-agents plan) operates over this
  whole tree, not a single workspace. This module is how a tree is listed, how a new top-level dir
  becomes a real workspace (provision), how one is removed (deprovision), and how the tree is
  snapshotted/restored for **eval isolation** (snapshot before a run, restore after → no prod pollution).

  THE LINE: generic mechanism (git-remote provisioning + jj op-log), nothing cloud-specific. The
  control-plane workspace record is only written when this nexus runs the control-plane role.

  **Security:** the workspace tree is JUST the top-level workspace folders — never `.nexus` (the tenant
  DB + secrets) or `cache`. A general run is given a staging COPY of these folders (see
  `stage/0` + `Nexus.Agent`), so the sandbox never sees `.nexus`.
  """
  require Logger
  alias Nexus.Paths

  # Never treat the nexus's own dirs (DB, replication, cache) or dotfiles as workspaces.
  @skip ~w(.nexus cache)

  @doc "Top-level workspace folder names under WB_DATA (excludes `.nexus`, `cache`, dotfiles)."
  def list do
    case File.ls(Paths.data_dir()) do
      {:ok, names} ->
        for n <- Enum.sort(names),
            n not in @skip,
            not String.starts_with?(n, "."),
            File.dir?(Path.join(Paths.data_dir(), n)),
            do: n

      _ ->
        []
    end
  end

  @doc "Absolute working dir for a workspace name (under WB_DATA)."
  def work_dir(name), do: Path.join(Paths.data_dir(), name)

  @doc "Bare repo path for a workspace name (under the durable repos root)."
  def bare(name), do: Nexus.Git.bare_path(Paths.repos_root(), name)

  @doc "Is this workspace registered (its bare repo exists)?"
  def registered?(name), do: Nexus.Git.bare?(bare(name))

  @doc """
  Register an on-disk top-level dir as a real workspace: provision its bare repo + working tree
  (+ jj colocation), commit its current contents, record it in the control plane (control-plane role
  only), and remount so it serves. Idempotent. `{:ok, name} | {:error, reason}`. `name` must be a
  safe single path segment (no `/`, no `..`).
  """
  def provision(name, org \\ nil) when is_binary(name) do
    cond do
      not safe_name?(name) -> {:error, :bad_name}
      not File.dir?(work_dir(name)) -> {:error, :no_dir}
      true ->
        Nexus.Git.provision_remote(bare(name), work_dir(name))
        Nexus.Git.commit(work_dir(name), "workspace #{name}: snapshot")
        if Nexus.ControlPlane.enabled?() do
          Nexus.ControlPlane.put(org || secrets_org(), :workspace, name, %{name: name, nexus_id: nexus_id()})
        end
        remount()
        {:ok, name}
    end
  end

  @doc """
  Remove a workspace entirely — working tree, bare repo, control-plane record — then remount. Used by
  eval restore (delete workspaces created since the snapshot) and the workspace-delete cleanup. `:ok`.
  Refuses unsafe names. NEVER touches `.nexus`/`cache` (not workspaces).
  """
  def deprovision(name, org \\ nil) when is_binary(name) do
    if safe_name?(name) and name not in @skip do
      File.rm_rf(work_dir(name))
      File.rm_rf(bare(name))
      if Nexus.ControlPlane.enabled?(), do: Nexus.ControlPlane.delete(org || secrets_org(), :workspace, name)
      remount()
      :ok
    else
      {:error, :bad_name}
    end
  end

  @doc "Provision every top-level dir that isn't yet a registered workspace (general-run auto-register)."
  def register_new(org \\ nil) do
    for n <- list(), not registered?(n), do: provision(n, org)
  end

  @doc """
  A tree snapshot for eval isolation: the current workspace set + each one's jj op-id (`Nexus.JJ`).
  `restore/2` returns the tree to exactly this — deleting workspaces created since and reverting the
  survivors' edits. `%{names: [name], ops: %{name => op_id | nil}}`.
  """
  def snapshot do
    names = list()

    ops =
      for n <- names, into: %{} do
        case Nexus.JJ.snapshot(work_dir(n)) do
          {:ok, op} -> {n, op}
          _ -> {n, nil}
        end
      end

    %{names: names, ops: ops}
  end

  @doc """
  Restore the tree to a `snapshot/0`: deprovision workspaces created since (not in `names`), then
  jj-restore each surviving workspace to its captured op-id. The dev-mode/eval rollback. `:ok`.
  """
  def restore(%{names: names, ops: ops}, org \\ nil) do
    for n <- list(), n not in names, do: deprovision(n, org)

    for {n, op} <- ops, is_binary(op), File.dir?(work_dir(n)) do
      Nexus.JJ.restore(work_dir(n), op)
    end

    remount()
    :ok
  end

  @doc """
  Stage a COPY of the workspace tree (just the workspace folders, never `.nexus`) into `dest` — the
  isolated `/work` a general run operates on. Returns the list of names copied (the "before" set).
  """
  def stage(dest) do
    File.mkdir_p!(dest)
    names = list()
    for n <- names, do: copy_clean(work_dir(n), Path.join(dest, n))
    names
  end

  @doc """
  Apply a general run's staging tree back to WB_DATA: every top-level dir in `staging` that is NEW
  (not in `before`) is moved in + provisioned as a workspace; an existing one that changed is copied
  back + committed. Returns the list of newly-provisioned workspace names.
  """
  def sync_back(staging, before, org \\ nil) do
    case File.ls(staging) do
      {:ok, names} ->
        for n <- Enum.sort(names),
            n not in @skip,
            not String.starts_with?(n, "."),
            safe_name?(n),
            File.dir?(Path.join(staging, n)),
            reduce: [] do
          acc ->
            src = Path.join(staging, n)
            dst = work_dir(n)

            if n in before do
              # Existing workspace edited in the run — copy working files back + commit (no-op if same).
              copy_clean(src, dst)
              Nexus.Git.commit(dst, "general: update #{n}")
              acc
            else
              # New top-level dir → a brand-new workspace.
              copy_clean(src, dst)
              case provision(n, org) do
                {:ok, _} -> [n | acc]
                _ -> acc
              end
            end
        end
        |> Enum.reverse()

      _ ->
        []
    end
  end

  # ── helpers ──
  # Recursively copy a workspace's WORKING files, skipping VCS internals (.git/.jj) — the agent operates
  # on working files; the nexus owns version control. (cp_r of a git dir also dies on read-only objects.)
  @vcs ~w(.git .jj)
  defp copy_clean(src, dst) do
    File.mkdir_p!(dst)

    case File.ls(src) do
      {:ok, entries} ->
        for e <- entries, e not in @vcs do
          s = Path.join(src, e)
          d = Path.join(dst, e)
          if File.dir?(s), do: copy_clean(s, d), else: File.cp!(s, d)
        end

      _ ->
        :ok
    end
  end

  # Remount so a new/removed workspace serves — but ONLY when this nexus is actually serving (mounts
  # populated). A pure compile/test never booted the server, so skip the (slow) recompile there.
  defp remount do
    if Application.get_env(:nexus, :mounts), do: Nexus.Server.remount()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # A workspace name is ONE safe path segment: no separators, no traversal, no leading dot.
  defp safe_name?(n) do
    is_binary(n) and n != "" and n not in @skip and
      not String.contains?(n, "/") and not String.contains?(n, "..") and
      not String.starts_with?(n, ".")
  end

  defp secrets_org do
    System.get_env("NEXUS_TENANT") ||
      (Nexus.ControlPlane.enabled?() && Nexus.Auth.Accounts.nexus_org()) ||
      Nexus.Store.default_tenant()
  end

  defp nexus_id, do: Application.get_env(:nexus, :nexus_name, "")
end
