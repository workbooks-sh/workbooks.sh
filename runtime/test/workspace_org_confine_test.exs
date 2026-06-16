defmodule WorkspaceOrgConfineTest do
  @moduledoc """
  wb-u6su: the kanban/OQL workspace .org routes (/api/oql/query, board-views, and the
  PATCH headline write) must not let an authenticated tenant read OR patch another
  tenant's (or an arbitrary host) .org file by absolute path. Desktop stays trusted
  (single-user machine); cloud/shared confines under the tenant's workspace root.
  Exercises the pure, testable Workbooks.Web.confine_workspace_org/3 (same shape as
  confined_workdir/4).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Web

  setup do
    prev = System.get_env("WB_DATA")
    base = Path.join(System.tmp_dir!(), "wb-u6su-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", base)
    File.mkdir_p!(Path.join([base, "wb-runs", "tenantA"]))
    File.mkdir_p!(Path.join([base, "wb-runs", "tenantB"]))
    File.write!(Path.join([base, "wb-runs", "tenantB", "secret.org"]), "* tenantB private\n")
    on_exit(fn ->
      File.rm_rf(base)
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
    end)
    {:ok, base: base}
  end

  defp root(base, t), do: Path.expand(Path.join([base, "wb-runs", t]))

  # --- CLOUD (desktop? = false): confine under the tenant root, no escape ---

  test "cloud: tenantA cannot escape to tenantB's .org (or any host file)", %{base: base} do
    rootA = root(base, "tenantA")
    realB = root(base, "tenantB")

    for p <- [
          "../tenantB/secret.org",
          "../../wb-runs/tenantB/secret.org",
          "x/../../../tenantB/secret.org",
          "/etc/passwd.org",
          "#{base}/wb-runs/tenantB/secret.org"
        ] do
      case Web.confine_workspace_org(false, "tenantA", p) do
        {:ok, abs} ->
          # Either rejected, OR safely re-rooted UNDER tenantA (a leading "/" is
          # stripped so an absolute path lands inside the tenant root, never at the
          # real target). Security property: resolved under tenantA's root and NOT
          # under tenantB's real root / an arbitrary host path.
          assert abs == rootA or String.starts_with?(abs, rootA <> "/"),
                 "#{p} escaped to #{abs} (root #{rootA})"

          refute String.starts_with?(abs, realB <> "/"),
                 "#{p} reached tenantB's real root: #{abs}"

        {:error, _} ->
          :ok
      end
    end
  end

  test "cloud: a relative .org lands UNDER the tenant root", %{base: base} do
    assert {:ok, abs} = Web.confine_workspace_org(false, "tenantA", "board.org")
    assert abs == Path.join(root(base, "tenantA"), "board.org")
  end

  test "cloud: non-.org is rejected", _ do
    assert {:error, :badpath} = Web.confine_workspace_org(false, "tenantA", "../../etc/passwd")
    assert {:error, :badpath} = Web.confine_workspace_org(false, "tenantA", "x.txt")
  end

  test "cloud: a FILE symlink planted in the tenant root cannot point OUT", %{base: base} do
    link = Path.join(root(base, "tenantA"), "leak.org")
    File.ln_s(Path.join([base, "wb-runs", "tenantB", "secret.org"]), link)
    assert {:error, :escape} = Web.confine_workspace_org(false, "tenantA", "leak.org")
  end

  test "cloud: an INTERMEDIATE DIRECTORY symlink cannot climb to another tenant", %{base: base} do
    # dirlink/ -> tenantB ; reading dirlink/secret.org must NOT reach tenantB
    # (the leaf-only realpath missed this — the per-component resolve closes it).
    File.ln_s(root(base, "tenantB"), Path.join(root(base, "tenantA"), "dirlink"))
    assert {:error, :escape} = Web.confine_workspace_org(false, "tenantA", "dirlink/secret.org")
    # also for a not-yet-existing leaf to be WRITTEN through the dir symlink
    assert {:error, :escape} = Web.confine_workspace_org(false, "tenantA", "dirlink/new.org")
  end

  test "cloud: tenant id itself cannot smuggle a path segment", %{base: base} do
    # a hostile tenant string is charset-collapsed to one safe segment
    assert {:ok, abs} = Web.confine_workspace_org(false, "../../etc", "board.org")
    refute String.contains?(abs, "..")
    assert String.starts_with?(abs, Path.expand(Path.join([base, "wb-runs"])) <> "/")
  end

  # --- DESKTOP (desktop? = true): trusted absolute local path preserved ---

  test "desktop: an absolute local .org is allowed (single-user, unbroken)" do
    assert {:ok, abs} = Web.confine_workspace_org(true, "local", "/Users/me/notes/board.org")
    assert abs == "/Users/me/notes/board.org"
  end

  test "desktop: `..` text still rejected" do
    assert {:error, :badpath} = Web.confine_workspace_org(true, "local", "/Users/me/../../etc/x.org")
  end

  test "empty/nil path -> nopath" do
    assert {:error, :nopath} = Web.confine_workspace_org(false, "tenantA", "")
    assert {:error, :nopath} = Web.confine_workspace_org(false, "tenantA", nil)
  end
end
