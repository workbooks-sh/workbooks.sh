defmodule Workbooks.Sessions do
  @moduledoc """
  Session resume flow (wb-11ck.24). A session is *warm* when its Instance is live
  in the BEAM, *cold* when only its VFS persists (on disk, or in cold storage /
  frozen). Resume reconciles the two: warm → reuse the running Instance; cold →
  restore the VFS, start the Instance, mark it active. Prefetch-on-auth warms the
  VFS cache ahead of first use without starting the Instance.

  The registry is the SQLite ControlPlane (single-machine). Going multi-machine
  swaps it for Postgres (Backend.Postgres) — the same flow, a different registry.
  """
  alias Workbooks.{ControlPlane, Instance, Lifecycle}

  @doc "Is a session warm — a live Instance in the BEAM?"
  def warm?(id), do: match?([_], Registry.lookup(Instance.Registry, id))

  @doc """
  Resume a session. Warm → reuse the live Instance. Cold → restore the VFS, start
  the Instance from `bytes`, mark active. Returns {:warm, :already_active} or
  {:cold, vfs_path}. `opts`: :cold_dir/:live_dir (restore frozen VFS), :policy.
  """
  def resume(id, bytes, opts \\ []) do
    if warm?(id) do
      {:warm, :already_active}
    else
      vfs = ensure_vfs(id, ControlPlane.get(id), opts)
      {:ok, _} = Instance.Supervisor.start_instance(id, bytes, Keyword.put(opts, :vfs, vfs))
      ControlPlane.set_state(id, "active")
      {:cold, vfs}
    end
  end

  @doc """
  Prefetch-on-auth: ensure the session VFS is local (restoring from cold storage
  if needed) without starting the Instance — warms the cache so the first request
  is fast. {:ok, vfs_path} | :error (unknown session).
  """
  def prefetch(id, opts \\ []) do
    case ControlPlane.get(id) do
      nil -> :error
      row -> {:ok, ensure_vfs(id, row, opts)}
    end
  end

  # Resolve the VFS to start/restore from: a local file is the warm cache; a
  # frozen session is restored from cold storage; otherwise a fresh store.
  defp ensure_vfs(_id, nil, opts), do: Keyword.get(opts, :vfs, ":memory:")

  defp ensure_vfs(id, %{state: state, vfs_path: path}, opts) do
    cold = Keyword.get(opts, :cold_dir)

    cond do
      is_binary(path) and path != ":memory:" and File.exists?(path) -> path
      state == "frozen" and cold -> elem(Lifecycle.resume(id, cold, live_dir(opts)), 1)
      true -> path || Keyword.get(opts, :vfs, ":memory:")
    end
  end

  defp live_dir(opts), do: Keyword.get(opts, :live_dir, System.tmp_dir!())
end
