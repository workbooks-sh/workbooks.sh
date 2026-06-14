defmodule Workbooks.SharedFolderTest do
  @moduledoc """
  Phase 3 — Shared folders. This is the SOLE capability that moves bytes across a
  tenant boundary, so the tests are adversarial about confinement: only the owner
  can share, only the named recipient can add, and an add copies EXACTLY the shared
  folder — never a sibling folder, never a repo-root secret (the ledger / signing
  keys), never `..`.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{SharedFolder, Git, ControlPlane}

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wb-share-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)

    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(data)
    end)

    :ok
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # Seed a tenant repo with a set of {relpath => content} files and commit them.
  defp seed(tenant, files) do
    dir = Git.ensure_repo(tenant)

    Enum.each(files, fn {rel, content} ->
      abs = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end)

    Git.commit_and_push(dir, "seed", tenant)
    dir
  end

  test "owner can share a real folder; non-owner / bad inputs are rejected" do
    owner = uniq("acme")
    mate = uniq("beta")
    seed(owner, %{"shared/brand/logo.svg" => "<svg/>", "shared/brand/colors.txt" => "mint"})

    # the allow-list reflects the real shared/ tree
    assert "brand" in SharedFolder.shareable(owner)

    assert {:ok, grant} = SharedFolder.share(owner, "brand", mate, :read)
    assert grant.owner == owner and grant.folder == "brand" and grant.recipient == mate

    # a folder the owner does NOT have under shared/ → no_such_folder
    assert {:error, :no_such_folder} = SharedFolder.share(owner, "ghost", mate, :read)
    # sharing with yourself, an unknown mode, or a path-shaped name → bad_request / no_such_folder
    assert {:error, :bad_request} = SharedFolder.share(owner, "brand", owner, :read)
    assert {:error, :bad_request} = SharedFolder.share(owner, "brand", mate, :sudo)
    assert {:error, :no_such_folder} = SharedFolder.share(owner, "../secrets", mate, :read)

    # a malformed recipient (control char / path / too long / empty) is rejected as
    # bad_request — not minted as an orphan grant (the tenant?/1 format floor)
    assert {:error, :bad_request} = SharedFolder.share(owner, "brand", "bad\nid", :read)
    assert {:error, :bad_request} = SharedFolder.share(owner, "brand", "../../x", :read)
    assert {:error, :bad_request} = SharedFolder.share(owner, "brand", "", :read)
    assert {:error, :bad_request} = SharedFolder.share(owner, "brand", String.duplicate("z", 200), :read)
  end

  test "add_to_workspace copies ONLY the shared folder — not siblings, not root secrets" do
    owner = uniq("acme")
    mate = uniq("beta")

    seed(owner, %{
      "shared/brand/logo.svg" => "<svg/>",
      "shared/brand/nested/colors.txt" => "mint",
      # a SIBLING folder under shared/ that is NOT shared
      "shared/private/secret-plan.md" => "TOP SECRET",
      # repo-root files that must NEVER travel
      "ledger.org" => "signed ledger entries",
      "api-key.txt" => "sk-LIVE-do-not-leak"
    })

    {:ok, grant} = SharedFolder.share(owner, "brand", mate, :read)
    assert {:ok, %{folder: "brand", files: files}} = SharedFolder.add_to_workspace(mate, grant.id)

    mate_dir = Git.repo_path(mate)
    dest = Path.join(mate_dir, "workspace/#{owner}__brand")

    # the shared folder's contents arrived (flattened to the dest root)
    assert File.read!(Path.join(dest, "logo.svg")) =~ "svg"
    assert File.read!(Path.join(dest, "nested/colors.txt")) =~ "mint"
    assert Enum.any?(files, &String.ends_with?(&1, "logo.svg"))

    # NOTHING outside shared/brand crossed: no sibling, no root secret, anywhere in mate's repo
    {all, 0} = System.cmd("git", ["-C", mate_dir, "ls-files"], stderr_to_stdout: true)
    refute all =~ "secret-plan"
    refute all =~ "ledger.org"
    refute all =~ "api-key"
    refute all =~ "TOP SECRET"
    # belt-and-suspenders: grep the whole vendored tree for the secret strings
    {grep, _} = System.cmd("grep", ["-rl", "TOP SECRET", mate_dir], stderr_to_stdout: true)
    assert grep == ""
    {grep2, _} = System.cmd("grep", ["-rl", "do-not-leak", mate_dir], stderr_to_stdout: true)
    assert grep2 == ""
  end

  test "only the named recipient can add — a stranger or wrong recipient gets not_found, no copy" do
    owner = uniq("acme")
    mate = uniq("beta")
    stranger = uniq("evil")
    seed(owner, %{"shared/brand/logo.svg" => "<svg/>"})
    {:ok, grant} = SharedFolder.share(owner, "brand", mate, :read)

    # a different tenant holding a real grant id cannot redeem it
    assert {:error, :not_found} = SharedFolder.add_to_workspace(stranger, grant.id)
    # a guessed / non-existent grant id → not_found
    assert {:error, :not_found} = SharedFolder.add_to_workspace(mate, "deadbeefdeadbeef")
    # the owner is not the recipient either
    assert {:error, :not_found} = SharedFolder.add_to_workspace(owner, grant.id)

    # the stranger's repo never received anything
    stranger_dir = Git.repo_path(stranger)
    refute File.dir?(Path.join(stranger_dir, "workspace"))
  end

  test "revoke is owner-only and blocks future adds" do
    owner = uniq("acme")
    mate = uniq("beta")
    seed(owner, %{"shared/brand/logo.svg" => "<svg/>"})
    {:ok, grant} = SharedFolder.share(owner, "brand", mate, :read)

    # the recipient cannot revoke the owner's grant
    assert {:error, :not_found} = SharedFolder.revoke(mate, grant.id)
    assert ControlPlane.get_share(grant.id) != nil

    # the owner can; afterward the grant is gone and adds fail closed
    assert :ok = SharedFolder.revoke(owner, grant.id)
    assert ControlPlane.get_share(grant.id) == nil
    assert {:error, :not_found} = SharedFolder.add_to_workspace(mate, grant.id)
  end

  test "shared_by / shared_with reflect the grant from each side" do
    owner = uniq("acme")
    mate = uniq("beta")
    seed(owner, %{"shared/brand/logo.svg" => "<svg/>"})
    {:ok, grant} = SharedFolder.share(owner, "brand", mate, :draft)

    assert Enum.any?(SharedFolder.shared_by(owner), &(&1.id == grant.id))
    assert Enum.any?(SharedFolder.shared_with(mate), &(&1.id == grant.id))
    # not visible to an uninvolved tenant
    assert SharedFolder.shared_with(uniq("nobody")) == []
  end
end
